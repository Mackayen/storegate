#!/usr/bin/env bash
# Daily backup for the free Supabase plan, which has no automatic backups.
# Needs the Postgres client tools (pg_dump) and the database connection string from
# Supabase > Project Settings > Database > Connection string (use the session pooler URI).
#
#   export SUPABASE_DB_URL='postgresql://postgres.xxxx:PASSWORD@aws-0-xx.pooler.supabase.com:5432/postgres'
#   ./scripts/backup.sh /path/to/backups
#
# Run it from cron (Linux) or Task Scheduler (Windows with WSL or Git Bash) once a day and copy
# the folder somewhere off the machine. Keep the connection string out of the repository.
set -euo pipefail
: "${SUPABASE_DB_URL:?Set SUPABASE_DB_URL first}"
dir="${1:?Give a backup folder}"
mkdir -p "$dir"
file="$dir/storegate-$(date +%Y%m%d-%H%M%S).sql.gz"
pg_dump --no-owner --no-privileges --schema=public "$SUPABASE_DB_URL" | gzip > "$file"
chmod 600 "$file"
find "$dir" -name 'storegate-*.sql.gz' -mtime +30 -delete
echo "Saved $file"
