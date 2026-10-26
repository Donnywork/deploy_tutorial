#!/usr/bin/env bash
# audit.sh <sha> <action> <result> <duration-s> — 部署审计(F4/P10):
# 谁、何时、对哪个 SHA、做了什么、结果如何。一行一条,好 grep 好归档。
# 残余风险(两层):deploy 用户能调用本脚本伪造/注水条目(sudoers 放行了它);
# /var/log/demo-app 目录归 deploy 属主,它还能删改 audit.log(含 symlink 变体)。
# 修正方向 = syslog 远程转发(高级册第 8 章)+ 日志目录收归 root。
set -euo pipefail
. /opt/demo-app/bin/app.conf

SHA="${1:?sha required}"
ACTION="${2:?action required}"
RESULT="${3:?result required}"
DUR="${4:-0}"
ACTOR="${SUDO_USER:-manual}"

mkdir -p "$(dirname "$AUDIT_LOG")"
printf '%s actor=%s action=%s sha=%s result=%s duration=%ss\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ACTOR" "$ACTION" "$SHA" "$RESULT" "$DUR" >> "$AUDIT_LOG"
logger -t demo-app-deploy "actor=$ACTOR action=$ACTION sha=$SHA result=$RESULT duration=$DUR"
