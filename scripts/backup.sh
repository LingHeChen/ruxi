#!/bin/sh
set -eu
: "${DATABASE_URL:?DATABASE_URL is required}"
: "${BACKUP_ROOT:?BACKUP_ROOT must be a separate durable backup directory}"
: "${ERASURE_LEDGER_PATH:?ERASURE_LEDGER_PATH must be set}"
umask 077
mkdir -p "$BACKUP_ROOT"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
# Use a service/PGPASSFILE in production rather than printing credentials.
PGDATABASE="$DATABASE_URL" pg_dump --schema=ruxi --format=custom --file="$BACKUP_ROOT/$stamp.dump.tmp"
mv "$BACKUP_ROOT/$stamp.dump.tmp" "$BACKUP_ROOT/$stamp.dump"
if [ -f "$ERASURE_LEDGER_PATH" ]; then
  cp "$ERASURE_LEDGER_PATH" "$BACKUP_ROOT/$stamp.erasure.jsonl"
fi
# Restore always consumes the newest independent ledger, not only this historical copy.
printf '%s\n' "$stamp" > "$BACKUP_ROOT/latest-completed.tmp"
mv "$BACKUP_ROOT/latest-completed.tmp" "$BACKUP_ROOT/latest-completed"
