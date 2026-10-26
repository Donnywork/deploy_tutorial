#!/usr/bin/env bash
# backup-naive.sh — 初级册第 6 章的备份脚本(DB + 文件存储)。
# 手动跑:sam@server: ./backup-naive.sh
# 定时跑:crontab -e 加一行(见第 6 章)
set -euo pipefail
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST=$HOME/backups/demo-app
mkdir -p "$DEST/db" "$DEST/storage"

echo "==> dumping database"
docker exec demo-app-db pg_dump -U demo_app --format=custom demo_app > "$DEST/db/$STAMP.dump"

echo "==> archiving file storage"
tar -czf "$DEST/storage/$STAMP.tar.gz" -C /srv/demo-app storage

echo "==> pruning: keep newest 14"
ls -1t "$DEST/db" | tail -n +15 | while read -r f; do rm -f "$DEST/db/$f"; done
ls -1t "$DEST/storage" | tail -n +15 | while read -r f; do rm -f "$DEST/storage/$f"; done

echo "==> latest:"
ls -lh "$DEST/db" | tail -3
