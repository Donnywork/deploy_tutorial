#!/usr/bin/env bash
# check-config.sh <sha> — 以 service 用户身份、加载真实 runtime.env,
# 运行该 release 的配置预检(缺配置必须在切换前被发现)。
# root 经 sudo 调用(deploy 用户在 sudoers 白名单里放行了本脚本)。
set -euo pipefail
. /opt/demo-app/bin/app.conf

SHA="${1:-}"
case "$SHA" in
  ""|*[!0-9a-f]*) echo "check-config: bad sha" >&2; exit 64 ;;
esac
[ "${#SHA}" -eq 40 ] || { echo "check-config: sha must be 40 hex" >&2; exit 64; }

REL="$SRV_ROOT/releases/$SHA"
[ -d "$REL" ] || { echo "check-config: release not found: $REL" >&2; exit 66; }

exec runuser -u "$APP_USER" -- bash -c "set -a; . '$ENV_FILE'; exec node '$REL/dist/config.js' --check-config"
