#!/usr/bin/env bash
# deploy.sh — 部署管线本体(root 拥有;由 deploy-entry 以 deploy 用户拉起)。
#
# 管线(每一步的失败行为都有定义,退出码见文末表):
#   flock 锁 → 冻结开关 → 幂等检查 → fetch+祖先校验 → 旧提交跳过 →
#   预检(磁盘/Node/lockfile) → 导出+构建(.partial) → 提升 release →
#   配置预检 → 备份 → 迁移 → 原子切换 current → 重启 → 健康检查+soak →
#   失败自动回切 → 保留策略 → 审计
set -Eeuo pipefail
umask 022

. /opt/demo-app/bin/app.conf

START_TS=$(date +%s)
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() { # die <exit-code> <step> <message>
  local rc=$1 step=$2; shift 2
  printf '%s FAILED step=%s: %s\n' "$(date -u +%H:%M:%S)" "$step" "$*" >&2
  sudo -n /opt/demo-app/bin/audit.sh "${SHA:-unknown}" deploy "fail:$rc:$step" \
    "$(( $(date +%s) - START_TS ))" >/dev/null 2>&1 || true
  exit "$rc"
}

# ---------- 0. 参数 ----------
SHA="${1:-}"
case "$SHA" in
  ""|*[!0-9a-f]*) die 65 arg "usage: deploy.sh <40-hex-sha>" ;;
esac
[ "${#SHA}" -eq 40 ] || die 65 arg "sha must be 40 hex chars (got ${#SHA})"
log "=== deploy $SHA start ==="

# ---------- 1. 紧急开关(E8)----------
[ ! -e "$FREEZE_FILE" ] || die 70 freeze "deploys frozen: $FREEZE_FILE exists"

# ---------- 2. 串行锁(B3)----------
# workflow 的 concurrency 是第一道防线,这道 flock 是第二道:
# 覆盖手动触发、workflow 排队行为差异、以及卡死的 runner。
exec 9>"$LOCK_FILE"
flock -n 9 || die 75 lock "another deploy is running (holds $LOCK_FILE)"

# ---------- 3. 幂等:该 SHA 已在线且健康 → 直接成功(B2)----------
CURRENT=""
[ -L "$SRV_ROOT/current" ] && CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")
if [ "$CURRENT" = "$SHA" ]; then
  if sudo -n /opt/demo-app/bin/healthcheck.sh "$SHA" >/dev/null 2>&1; then
    log "sha already live and healthy — nothing to do (idempotent success)"
    sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))" >/dev/null 2>&1 || true
    exit 0
  fi
  log "sha is current but unhealthy — will redeploy it"
fi

# ---------- 4. fetch + "必须是 main 的祖先"(B1)----------
log "fetching origin/main ..."
git --git-dir="$REPO_CACHE" fetch --prune -q origin \
  || die 11 fetch "git fetch failed (network? deploy key?)"
if ! git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" refs/heads/main 2>/dev/null; then
  die 12 verify "SHA is not an ancestor of origin/main — rejected (force-push? wrong branch?)"
fi

# ---------- 5. 比线上旧 → 跳过(B2;回滚请用 rollback.sh,H8/E7)----------
if [ -n "$CURRENT" ] && [ "$CURRENT" != "$SHA" ]; then
  case "$CURRENT" in
    *[!0-9a-f]*) ;;
    *)
      if git --git-dir="$REPO_CACHE" merge-base --is-ancestor "$SHA" "$CURRENT"; then
        log "skip: $SHA is older than live $CURRENT — use rollback.sh to go back"
        exit 0
      fi
      ;;
  esac
fi

# ---------- 6. 预检(C2/C5)----------
avail_kb=$(df -Pk "$SRV_ROOT" | awk 'NR==2{print $4}')
[ "$avail_kb" -gt 1048576 ] || die 13 preflight "less than 1 GiB free under $SRV_ROOT"
# 以"目标提交里的 .node-version"为准(参考设计),没有该文件才退回 app.conf
# (|| true:提交里没有该文件时 git 以 128 退出,pipefail 下不能让整条命令裸退)
want_major=$(git --git-dir="$REPO_CACHE" show "$SHA":.node-version 2>/dev/null \
  | sed 's/^v\([0-9]*\).*/\1/' || true)
want_major="${want_major:-$NODE_MAJOR}"
node_major=$(node --version | sed 's/^v\([0-9]*\).*/\1/')
[ "$node_major" = "$want_major" ] \
  || die 14 preflight "server Node major=$node_major, .node-version wants=$want_major"
git --git-dir="$REPO_CACHE" show "$SHA":pnpm-lock.yaml >/dev/null 2>&1 \
  || die 15 preflight "commit has no pnpm-lock.yaml (C2: lockfile discipline)"

# ---------- 7. 导出精确提交 → 以 deploy 身份构建(C1)----------
PARTIAL="$SRV_ROOT/.partial"
rm -rf "$PARTIAL"
mkdir -p "$PARTIAL"
git --git-dir="$REPO_CACHE" archive "$SHA" | tar -x -C "$PARTIAL"
log "building as $DEPLOY_USER in .partial/ ..."
if ! ( cd "$PARTIAL" && env GIT_SHA="$SHA" bash -c "$BUILD_CMD" ); then
  rm -rf "$PARTIAL"
  die 20 build "build failed — no release created, live site untouched"
fi

# ---------- 8. 提升 .partial → releases/<sha>(原子 rename,同文件系统)----------
# 同 SHA 重建时先把旧目录挪开再换入,避免 rm 与 mv 之间出现 current 指向空目录的窗口
if [ -d "$SRV_ROOT/releases/$SHA" ]; then
  mv "$SRV_ROOT/releases/$SHA" "$SRV_ROOT/releases/$SHA.old.$$"
fi
mv "$PARTIAL" "$SRV_ROOT/releases/$SHA"
rm -rf "$SRV_ROOT/releases/$SHA.old.$$"
log "release created: releases/$SHA"

# ---------- 9. 配置预检:以 service 用户 + 真实 runtime.env(E6/H6)----------
if ! sudo -n /opt/demo-app/bin/check-config.sh "$SHA"; then
  die 22 check-config "new release would crash on missing env — kept current release"
fi

# ---------- 10. 迁移前备份(P5:备份失败就绝不碰数据库)----------
log "pre-migration backup ..."
sudo -n /opt/demo-app/bin/backup.sh premigrate \
  || die 24 backup "pre-migration backup failed — refusing to migrate"

# ---------- 11. 迁移(advisory lock;失败则代码不切换,D3)----------
log "migrating (releases/$SHA/dist/migrate.js) ..."
sudo -n /opt/demo-app/bin/migrate-wrapper.sh "$SHA" \
  || die 26 migrate "migration failed — code NOT switched, live still on ${CURRENT:-nothing}"

# ---------- 12. 原子切换 current(ln -sfn + mv -T 两步 = 原子)----------
ln -sfn "releases/$SHA" "$SRV_ROOT/.current.tmp"
mv -T "$SRV_ROOT/.current.tmp" "$SRV_ROOT/current"
log "current -> releases/$SHA"

# ---------- 13. 重启单元 ----------
sudo -n systemctl restart $UNITS || die 28 restart "systemctl restart failed"

# ---------- 14. 健康检查(断言 SHA + DB 读写 + worker 心跳 + soak,P3/P4)----------
if ! sudo -n /opt/demo-app/bin/healthcheck.sh "$SHA"; then
  log "health check FAILED — rolling back to ${CURRENT:-(none)}"
  if [ -n "$CURRENT" ]; then
    ln -sfn "releases/$CURRENT" "$SRV_ROOT/.current.tmp"
    mv -T "$SRV_ROOT/.current.tmp" "$SRV_ROOT/current"
    sudo -n systemctl restart $UNITS || true
    if sudo -n /opt/demo-app/bin/healthcheck.sh "$CURRENT" >/dev/null 2>&1; then
      die 30 health "new release unhealthy; rolled back to $CURRENT (healthy). DB stays migrated — see expand/contract"
    else
      die 31 health "new release unhealthy AND rollback target unhealthy — HUMAN HELP NEEDED NOW"
    fi
  else
    die 32 health "first deployment failed health check; nothing to roll back to"
  fi
fi

# ---------- 15. 保留策略(F5:永不删 current、上一版、以及部署前的 current)----------
# 说明:$CURRENT 是"部署前线上跑的版本"——手动 rollback 后它未必是 mtime 最新,
# 但它是刚被人工验证过的退路,绝不能被 prune 掉。
prev=$(ls -1t "$SRV_ROOT/releases" | sed -n '2p')
ls -1t "$SRV_ROOT/releases" | tail -n +"$((KEEP_RELEASES + 1))" | while read -r r; do
  [ "$r" = "$SHA" ] && continue
  [ "$r" = "$prev" ] && continue
  [ "$r" = "$CURRENT" ] && continue
  rm -rf "$SRV_ROOT/releases/$r"
  log "pruned old release $r"
done

# ---------- 16. 审计 + 摘要(F4)----------
sudo -n /opt/demo-app/bin/audit.sh "$SHA" deploy ok "$(( $(date +%s) - START_TS ))"
log "=== deploy $SHA OK in $(( $(date +%s) - START_TS ))s ==="

# 退出码速查:
#  11 fetch 失败         12 SHA 不在 main 历史   13 磁盘不足
#  14 Node 版本不符      15 无 lockfile          20 构建失败(已清理 .partial)
#  22 配置预检失败       24 备份失败(拒绝迁移)  26 迁移失败(代码未切换)
#  28 重启失败           30 部署不健康已回切     31 回切后仍不健康(人工!)
#  32 首次部署不健康     64-65 参数非法          70 部署冻结      75 有部署在进行
