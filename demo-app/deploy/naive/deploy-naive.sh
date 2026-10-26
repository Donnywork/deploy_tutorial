#!/usr/bin/env bash
# deploy-naive.sh — 初级教程第 7 章的"v0 部署脚本":能用,但每一行都是教训。
# 在服务器上以日常用户(sam)运行;初级教程第 7 章会逐条"审判"它。
set -e
cd /srv/demo-app
echo "==> pulling latest code"
sudo -u app git pull --ff-only origin main
echo "==> installing dependencies (on the PRODUCTION machine — 罪状#2)"
sudo -u app pnpm install --frozen-lockfile
echo "==> building (on the PRODUCTION machine — 罪状#2)"
sudo -u app pnpm run build
echo "==> migrating (BEFORE switching code — 罪状#8:新旧代码/数据库可能错配)"
sudo -u app bash -c 'cd /srv/demo-app && set -a && . ./runtime.env && pnpm run migrate'
echo "==> restarting (hard restart, in-flight requests die — 罪状#1)"
sudo systemctl restart demo-app
echo "==> done. is it healthy? nobody knows — 罪状#4(没有健康检查)"
echo "deployed: $(sudo -u app git -C /srv/demo-app rev-parse --short HEAD)"
