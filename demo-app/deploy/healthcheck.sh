#!/usr/bin/env bash
# healthcheck.sh <sha> — "端口通了"不等于"新版本正常"(P3)。
# 必须同时断言:
#   1. /version 返回的正是目标 SHA(旧进程应答 = 假阳性,E2)
#   2. /health/ready 200(真实 DB 读写,不是只 ping 进程)
#   3. worker 心跳足够新(worker 崩溃循环 = 假阳性,E2)
#   4. 所有单元 active(不接受混合状态,P4/E3)
#   5. soak 窗口后再次确认(抓被 systemd 自动重启掩盖的崩溃循环,P3)
set -uo pipefail
. /opt/demo-app/bin/app.conf

SHA="${1:-}"
case "$SHA" in
  ""|*[!0-9a-f]*) echo "healthcheck: usage: healthcheck.sh <40-hex-sha> [port]" >&2; exit 64 ;;
esac
[ "${#SHA}" -eq 40 ] || { echo "healthcheck: sha must be 40 hex" >&2; exit 64; }

# 可选第 2 参数:端口覆盖(高级册蓝绿用——检查还在"台下"的新槽位)
PORT_OVERRIDE="${2:-}"
if [ -n "$PORT_OVERRIDE" ]; then
  case "$PORT_OVERRIDE" in
    *[!0-9]*) echo "healthcheck: bad port: $PORT_OVERRIDE" >&2; exit 64 ;;
  esac
  VERSION_URL="http://127.0.0.1:${PORT_OVERRIDE}/version"
  READY_URL="http://127.0.0.1:${PORT_OVERRIDE}/health/ready"
fi

probe() {
  local why="" version ready hb u
  version=$(curl -fsS --max-time 3 "$VERSION_URL" 2>/dev/null || true)
  ready=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$READY_URL" 2>/dev/null || echo 000)
  hb=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -Atc \
    "SELECT COALESCE(EXTRACT(EPOCH FROM now()-last_beat)::int, 999999) FROM worker_status WHERE id=1" \
    2>/dev/null || echo 999999)

  printf '%s' "$version" | grep -q "\"gitSha\":\"$SHA\"" || why="$why version!=sha"
  [ "$ready" = "200" ] || why="$why ready=$ready"
  [ "${hb:-999999}" -le "$WORKER_MAX_HEARTBEAT_AGE" ] || why="$why worker-heartbeat=${hb}s"
  for u in $UNITS; do
    systemctl is-active --quiet "$u" || why="$why unit:$u=$(systemctl is-active "$u")"
  done

  if [ -n "$why" ]; then echo "healthcheck: fail -$why" >&2; return 1; fi
  return 0
}

deadline=$(( $(date +%s) + HEALTH_WAIT_SECONDS ))
until probe; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "healthcheck: FAILED — not healthy within ${HEALTH_WAIT_SECONDS}s" >&2
    exit 1
  fi
  sleep 2
done

echo "healthcheck: initial pass — soaking ${SOAK_SECONDS}s ..."
sleep "$SOAK_SECONDS"
if probe; then
  echo "healthcheck: PASS sha=$SHA (post-soak)"
  exit 0
fi
echo "healthcheck: FAILED after soak — crash loop? check: journalctl -u demo-app-web -u demo-app-worker --since -2min" >&2
exit 1
