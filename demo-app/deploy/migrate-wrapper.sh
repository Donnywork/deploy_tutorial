#!/usr/bin/env bash
# migrate-wrapper.sh <sha> — root 经 sudo 调用;校验参数后以 service 用户
# 运行该 release 的迁移(参考设计:迁移代码由 root 持有的包装脚本执行)。
#
# 双层并发保护:
#   - 本脚本 flock:主机级快速失败
#   - migrate.js 内部 pg_advisory_lock:数据库级(跨主机也成立)
# 参数防御:sudoers 的 [0-9a-f]* glob 理论上可能匹配带空格的参数,
# 所以这里再验一次"恰好一个 40 位十六进制参数"。
set -euo pipefail
. /opt/demo-app/bin/app.conf

[ "$#" -eq 1 ] || { echo "migrate-wrapper: exactly one sha argument required (got $#)" >&2; exit 64; }
SHA="$1"
case "$SHA" in
  ""|*[!0-9a-f]*) echo "migrate-wrapper: bad sha" >&2; exit 64 ;;
esac
[ "${#SHA}" -eq 40 ] || { echo "migrate-wrapper: sha must be 40 hex" >&2; exit 64; }

REL="$SRV_ROOT/releases/$SHA"
[ -d "$REL/dist" ] || { echo "migrate-wrapper: release not found: $REL" >&2; exit 66; }

exec 8>/run/demo-app/migrate.lock
flock -n 8 || { echo "migrate-wrapper: another migration holds the lock" >&2; exit 68; }

# 不用 exec:外壳必须活着持有 flock 直到迁移结束;
# 8>&- 把锁 fd 关掉,不泄漏给 app 用户的进程链(纵深防御,防 app 侧提前放锁)。
runuser -u "$APP_USER" -- bash -c "set -a; . '$ENV_FILE'; exec node '$REL/dist/migrate.js'" 8>&-
