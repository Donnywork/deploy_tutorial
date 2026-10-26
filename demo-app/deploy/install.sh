#!/usr/bin/env bash
# install.sh <git-url-of-your-repo> — 在空服务器上引导整套部署系统(F1)。
# 以 root 运行;从仓库的 deploy/ 目录里执行。
# 本脚本做"机器相关"的部分;密钥与 GitHub 设置见中级册第 3/8 章。
set -euo pipefail

ORIGIN="${1:?usage: install.sh <git-url>}"
[ "$(id -u)" -eq 0 ] || { echo "install.sh: must run as root" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
APP=app
DEPLOY=deploy
SRV=/srv/demo-app
OPT=/opt/demo-app

echo "== 0/9 前置检查(缺什么装什么的教程见中级册第 2 章)=="
for cmd in git node pnpm docker systemctl runuser flock openssl visudo; do
  command -v "$cmd" >/dev/null || { echo "MISSING: $cmd — install it first"; exit 1; }
done

echo "== 1/9 创建用户(P7:三类身份,各司其职)=="
id "$APP"    >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$APP"
id "$DEPLOY" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$DEPLOY"
passwd -l "$APP" 2>/dev/null || true   # 两个账户都禁止密码登录
passwd -l "$DEPLOY" 2>/dev/null || true

echo "== 2/9 目录布局 =="
install -d -o root   -g root   -m 0755 "$OPT/bin" "$OPT/env" "$OPT/compose" /etc/tmpfiles.d
# /srv/demo-app 归 deploy:deploy —— deploy.sh 要在这里创建 .partial/current/repo.git(需要写权限)
install -d -o "$DEPLOY" -g "$DEPLOY" -m 0755 "$SRV"
install -d -o "$DEPLOY" -g "$DEPLOY" -m 0755 "$SRV/releases"
install -d -o "$APP"  -g "$APP"  -m 0750 "$SRV/storage"
install -d -o "$DEPLOY" -g "$DEPLOY" -m 0755 /var/log/demo-app
install -d -o root   -g root   -m 0700 /var/backups/demo-app
# /run 是 tmpfs,重启即空 → 用 tmpfiles 让锁目录开机自动出现
cat >/etc/tmpfiles.d/demo-app.conf <<'EOF'
d /run/demo-app 0755 deploy deploy -
EOF
systemd-tmpfiles --create /etc/tmpfiles.d/demo-app.conf

echo "== 3/9 安装部署脚本(root 拥有,deploy 不可写;F2:升级需手动重跑本步)=="
for f in app.conf deploy-entry deploy.sh healthcheck.sh check-config.sh \
         migrate-wrapper.sh backup.sh rollback.sh audit.sh; do
  install -o root -g root -m 0755 "$HERE/$f" "$OPT/bin/$f"
done
chmod 0644 "$OPT/bin/app.conf"

echo "== 4/9 sudoers 白名单 + 语法校验(写坏会让 sudo 全挂,必须先验)=="
install -o root -g root -m 0440 "$HERE/demo-app.sudoers" /etc/sudoers.d/demo-app
visudo -cf /etc/sudoers.d/demo-app

echo "== 5/9 systemd 单元(先 enable 不 start,等首次部署)=="
install -o root -g root -m 0644 "$HERE/demo-app-web.service"   /etc/systemd/system/
install -o root -g root -m 0644 "$HERE/demo-app-worker.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable demo-app-web.service demo-app-worker.service

echo "== 6/9 Postgres(compose 文件 + 一次性生成的密码)=="
install -o root -g root -m 0644 "$HERE/../docker-compose.yml" "$OPT/compose/docker-compose.yml"
if [ ! -f "$OPT/compose/.env" ]; then
  PW=$(openssl rand -hex 16)
  umask 077
  printf 'POSTGRES_PASSWORD=%s\n' "$PW" > "$OPT/compose/.env"
  echo "(created $OPT/compose/.env)"
fi
if [ ! -f "$OPT/env/runtime.env" ]; then
  PW=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$OPT/compose/.env")
  sed "s/__GENERATED_PASSWORD__/$PW/" "$HERE/env/runtime.env.example" \
    > "$OPT/env/runtime.env"
  chown root:"$APP" "$OPT/env/runtime.env"
  chmod 0640 "$OPT/env/runtime.env"
  echo "(created $OPT/env/runtime.env — root:app 0640)"
fi
docker compose --project-directory "$OPT/compose" up -d

echo "== 7/9 仓库镜像缓存(只读 deploy key 由你在第 8 章配置)=="
if [ ! -d "$SRV/repo.git" ]; then
  if ! sudo -u "$DEPLOY" git clone --mirror "$ORIGIN" "$SRV/repo.git"; then
    echo "WARN: clone failed — deploy 用户的 GitHub deploy key 还没配?"
    echo "      配好钥匙(中级册 3.4)后重跑本脚本即可(幂等)"
  fi
fi

echo "== 8/9 每日备份 cron =="
cat >/etc/cron.d/demo-app-backup <<'EOF'
17 3 * * * root /opt/demo-app/bin/backup.sh daily
EOF
chmod 0644 /etc/cron.d/demo-app-backup

echo "== 9/9 完成。下一步(中级册第 3/8 章)=="
cat <<EOF
  1. 为 deploy 用户配置 SSH 强制命令(中级册 3.2)
  2. 为 deploy 用户配置仓库的只读 deploy key(中级册 3.4)
  3. push 到 main,或手动触发首次部署(中级册 8.3)
  状态:units=enabled(not started)  repo=$SRV/repo.git  db=demo-app-db
EOF
