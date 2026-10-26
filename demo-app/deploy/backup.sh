#!/usr/bin/env bash
# backup.sh [daily|premigrate|manual] — root 持有。
# 备份范围 = 数据库 + 文件存储目录(文件存储不在备份里 = 迟早丢数据)。
# 保留策略(不只按次数):每类保留最近 N 份,**且 7 天内的一律保留**
# —— 部署频繁时也不会把历史挤光。
# 但请记住:没有做过恢复演练的备份等于没有。恢复步骤见中级册第 6 章。
set -euo pipefail
. /opt/demo-app/bin/app.conf

KIND="${1:-manual}"
case "$KIND" in
  daily|premigrate|manual) ;;
  *) echo "backup: kind must be daily|premigrate|manual" >&2; exit 64 ;;
esac

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP_DIR/db" "$BACKUP_DIR/storage"

db_out="$BACKUP_DIR/db/${KIND}-${STAMP}.dump"
st_out="$BACKUP_DIR/storage/${KIND}-${STAMP}.tar.gz"

# -Fc:pg_dump 的 custom 格式,支持 pg_restore 选择性恢复、压缩
# (失败即删半截文件:半份备份比没有更危险——它会挤占保留名额)
docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" --format=custom "$DB_NAME" > "$db_out" \
  || { rm -f "$db_out"; echo "backup: pg_dump failed" >&2; exit 1; }
chmod 600 "$db_out"

tar -czf "$st_out" -C "$(dirname "$STORAGE_DIR")" "$(basename "$STORAGE_DIR")" \
  || { rm -f "$st_out"; echo "backup: tar failed" >&2; exit 1; }
chmod 600 "$st_out"

# 组合保留:每类最近 N 份 + 7 天内全保(注意按 KIND 前缀过滤——
# premigrate 的 keep=10 不能侵蚀 daily 的 keep=14 名额)
keep=$BACKUP_KEEP_PREMIGRATE
[ "$KIND" = daily ] && keep=$BACKUP_KEEP_DAILY
[ "$KIND" = manual ] && keep=5

for dir in "$BACKUP_DIR/db" "$BACKUP_DIR/storage"; do
  ls -1t "$dir" 2>/dev/null | grep "^${KIND}-" | tail -n +"$((keep + 1))" | while read -r f; do
    [ -n "$f" ] || continue
    if [ -z "$(find "$dir/$f" -mtime -7 2>/dev/null)" ]; then
      rm -f "$dir/$f"
      echo "backup: pruned $dir/$f (older than 7d, beyond keep=$keep)"
    fi
  done
done

echo "backup[$KIND]: db=$(du -h "$db_out" | cut -f1) storage=$(du -h "$st_out" | cut -f1)"
logger -t demo-app-backup "kind=$KIND db=$db_out storage=$st_out"
