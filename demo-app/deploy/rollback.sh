#!/usr/bin/env bash
# rollback.sh [sha] — 一等公民回滚(E7/H8 修正)。管理员手动 sudo 运行。
#
# 三条铁律:
#   1. 不依赖外网:不 fetch、不 install —— GitHub 挂了也要能回滚(P9/C3)
#   2. 绝不动数据库:迁移不自动回滚(P2);数据库兼容性靠 expand/contract 保证
#   3. 有专门命令,不是"手动改软链":可计时、可演练、可审计
set -euo pipefail
. /opt/demo-app/bin/app.conf

# 与部署互斥(B3):部署进行中不允许回滚,否则会互相覆盖 current、互相 restart
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "rollback: a deploy holds $LOCK_FILE — refusing to race it" >&2; exit 75; }

CURRENT="none"
[ -L "$SRV_ROOT/current" ] && CURRENT=$(basename "$(readlink "$SRV_ROOT/current")")

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  # 无参默认:选"比 current 更旧的最新的一个"。
  # 不选"最新的非 current"——自动回切之后,最新的往往正是刚失败的那个新版本。
  CUR_MTIME=$(stat -c %Y "$SRV_ROOT/releases/$CURRENT" 2>/dev/null || echo 0)
  for r in $(ls -1t "$SRV_ROOT/releases"); do
    case "$r" in *[!0-9a-f]*) continue ;; esac
    [ "$r" = "$CURRENT" ] && continue
    if [ "$(stat -c %Y "$SRV_ROOT/releases/$r")" -lt "$CUR_MTIME" ]; then
      TARGET="$r"; break
    fi
  done
  [ -n "$TARGET" ] || { echo "rollback: no older release found to roll back to" >&2; exit 66; }
fi
case "$TARGET" in
  *[!0-9a-f]*) echo "rollback: bad sha" >&2; exit 64 ;;
esac
[ -d "$SRV_ROOT/releases/$TARGET" ] || { echo "rollback: release not found: $TARGET" >&2; exit 66; }

T0=$(date +%s)
ln -sfn "releases/$TARGET" "$SRV_ROOT/.current.tmp"
mv -T "$SRV_ROOT/.current.tmp" "$SRV_ROOT/current"
systemctl restart $UNITS
/opt/demo-app/bin/healthcheck.sh "$TARGET"
/opt/demo-app/bin/audit.sh "$TARGET" rollback ok "$(( $(date +%s) - T0 ))"
echo "rollback: $CURRENT -> $TARGET in $(( $(date +%s) - T0 ))s"
echo "rollback: DB was NOT touched (migrations never auto-rollback; see expand/contract)"
