#!/bin/bash
# Weekly repo integrity: restic check (5% data sample) on nfs+etcd + pgbackrest verify.
# Runs as root, weekly. Emails only on failure.
. /opt/backup/backup.env
export PATH=/usr/local/bin:/usr/bin:/bin HOME=/root RESTIC_CACHE_DIR="$BACKUP_ROOT/restic/cache"
PG="$PUSHGATEWAY/metrics/job/backup/instance/$BACKUP_INSTANCE"
FAIL=0; OUT=""
for repo in nfs etcd; do
  if RESTIC_REPOSITORY="$BACKUP_ROOT/restic/$repo" RESTIC_PASSWORD_FILE="$BACKUP_ROOT/restic/.${repo}-pass" /usr/local/bin/restic check --read-data-subset=5% >/tmp/ic-$repo.log 2>&1; then
    OUT="$OUT
  restic $repo : OK"
  else OUT="$OUT
  restic $repo : FAILED ($(tail -1 /tmp/ic-$repo.log))"; FAIL=$((FAIL+1)); fi
done
if sudo -u "$BACKUP_USER" HOME="/home/$BACKUP_USER" /usr/bin/pgbackrest --stanza="$PG_STANZA" verify >/tmp/ic-pg.log 2>&1; then
  OUT="$OUT
  pgbackrest : OK"
else OUT="$OUT
  pgbackrest : FAILED ($(tail -1 /tmp/ic-pg.log))"; FAIL=$((FAIL+1)); fi
printf 'backup_integrity_failures %s\nbackup_integrity_last_check %s\n' "$FAIL" "$(date +%s)" | curl -s --data-binary @- "$PG/kind/integrity"
[ "$FAIL" -gt 0 ] && printf 'Backup integrity check found %s problem(s):\n%s\n' "$FAIL" "$OUT" | "$BACKUP_ROOT/bin/send-mail.sh" "[Backup] INTEGRITY CHECK FAILED"
exit 0
