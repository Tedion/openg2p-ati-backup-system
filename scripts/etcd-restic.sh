#!/bin/bash
# Re-pack the plaintext etcd tarballs (shipped by the cluster's snapshot job) into an
# encrypted restic repo, then delete the plaintext. Runs as root, 6-hourly.
. /opt/backup/backup.env
export PATH=/usr/local/bin:/usr/bin:/bin HOME=/root RESTIC_CACHE_DIR="$BACKUP_ROOT/restic/cache"
export RESTIC_REPOSITORY="$BACKUP_ROOT/restic/etcd" RESTIC_PASSWORD_FILE="$BACKUP_ROOT/restic/.etcd-pass"
PG="$PUSHGATEWAY/metrics/job/backup/instance/$BACKUP_INSTANCE"
ST=1
if ls "$BACKUP_ROOT"/etcd-snapshots/*.tar.gz >/dev/null 2>&1; then
  if restic backup "$BACKUP_ROOT/etcd-snapshots" --tag etcd; then
    restic forget $RESTIC_KEEP --prune
    rm -f "$BACKUP_ROOT"/etcd-snapshots/*.tar.gz   # plaintext now safely in encrypted repo
    ST=1
  else ST=0; fi
fi
printf 'backup_status{backup_type="etcd"} %s\n' "$ST" | curl -s --data-binary @- "$PG/kind/etcd"
[ "$ST" -eq 1 ] && printf 'etcd_backup_last_success_timestamp %s\n' "$(date +%s)" | curl -s --data-binary @- "$PG/kind/etcdsuccess"
[ "$ST" -eq 0 ] && echo "etcd restic backup FAILED on $BACKUP_INSTANCE at $(date). Check $BACKUP_ROOT/restic/etcd + journalctl -u backup-etcd-restic." | "$BACKUP_ROOT/bin/send-mail.sh" "[Backup] etcd restic FAILED"
exit 0
