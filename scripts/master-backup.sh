#!/bin/bash
# Daily orchestrator: NFS restic + MinIO mirror, pushes metrics, sends ONE summary email.
# Runs as root via systemd. All environment specifics come from backup.env.
. /opt/backup/backup.env
export PATH=/usr/local/bin:/usr/bin:/bin HOME=/root RESTIC_CACHE_DIR="$BACKUP_ROOT/restic/cache"
PG="$PUSHGATEWAY/metrics/job/backup/instance/$BACKUP_INSTANCE"
FAIL=0; NFS=0; MINIO=0

# --- NFS (restic, encrypted+compressed) ---
export RESTIC_REPOSITORY="$BACKUP_ROOT/restic/nfs" RESTIC_PASSWORD_FILE="$BACKUP_ROOT/restic/.nfs-pass"
mountpoint -q "$NFS_MOUNT" || mount -t nfs -o ro,nfsvers=4.2,soft,timeo=50 "$NFS_SERVER:$NFS_EXPORT" "$NFS_MOUNT"
if mountpoint -q "$NFS_MOUNT"; then
  if ionice -c2 -n7 nice -n19 restic backup "$NFS_MOUNT" --tag nfs; then
    restic forget $RESTIC_KEEP --prune; NFS=1
  fi
fi
[ "$NFS" -eq 1 ] || FAIL=$((FAIL+1))
NFS_SZ=$(du -sh "$BACKUP_ROOT/restic/nfs" 2>/dev/null|cut -f1)

# --- MinIO (mc mirror, incremental) ---
if ionice -c2 -n7 nice -n19 mc mirror --overwrite "$MINIO_ALIAS/$MINIO_BUCKET" "$BACKUP_ROOT/minio-mirror/$MINIO_BUCKET"; then MINIO=1; fi
[ "$MINIO" -eq 1 ] || FAIL=$((FAIL+1))
MINIO_SZ=$(du -sh "$BACKUP_ROOT/minio-mirror" 2>/dev/null|cut -f1)

# --- metrics ---
AVAILH=$(df -h --output=avail "$BACKUP_ROOT"|tail -1|tr -d ' ')
AVAILB=$(df -B1 --output=avail "$BACKUP_ROOT"|tail -1|tr -d ' ')
NFSB=$(du -sb "$BACKUP_ROOT/restic/nfs" 2>/dev/null|cut -f1); MINIOB=$(du -sb "$BACKUP_ROOT/minio-mirror" 2>/dev/null|cut -f1)
NOW=$(date +%s)
printf 'backup_status{backup_type="nfs"} %s\nbackup_status{backup_type="minio"} %s\nbackup_size_bytes{backup_type="nfs"} %s\nbackup_size_bytes{backup_type="minio"} %s\nmaster_backup_failure_count %s\nbackup_disk_space_available_bytes %s\n' \
  "$NFS" "$MINIO" "${NFSB:-0}" "${MINIOB:-0}" "$FAIL" "$AVAILB" | curl -s --data-binary @- "$PG"
[ "$FAIL" -eq 0 ] && printf 'master_backup_last_success_timestamp %s\n' "$NOW" | curl -s --data-binary @- "$PG/kind/lastsuccess"

# --- daily summary email (pulls other sources' status from pushgateway) ---
PGM=$(curl -s "$PUSHGATEWAY/metrics")
st(){ echo "$PGM" | grep "backup_status{backup_type=\"$1\"" | grep "$BACKUP_INSTANCE" | grep -oE '[01]$' | head -1; }
ok(){ [ "$1" = "1" ] && echo OK || { [ -z "$1" ] && echo "?" || echo "*** FAIL ***"; }; }
DBST=$(st db); ETCDST=$(st etcd)
WAL=$(echo "$PGM" | grep 'pg_wal_size_bytes{' | grep "$PG_INSTANCE" | grep -oE '[0-9.e+]+$' | head -1)
WALF=$(echo "$PGM" | grep 'pg_archiver_failed_count{' | grep "$PG_INSTANCE" | grep -oE '[0-9]+$' | head -1)
BODY="OpenG2P Backup Report - $(date '+%Y-%m-%d %H:%M %Z')
Backup host: $BACKUP_INSTANCE

  NFS    : $(ok $NFS)    ($NFS_SZ, restic encrypted)
  MinIO  : $(ok $MINIO)    ($MINIO_SZ, mc mirror)
  DB     : $(ok ${DBST}) (pgBackRest WAL/PITR + daily diff)
  etcd   : $(ok ${ETCDST}) (restic encrypted)
  K8s    : rancher-backup -> lands on NFS (covered above)

  Disk free on $BACKUP_ROOT : $AVAILH
  Postgres WAL              : ${WAL%.*} bytes, archiver failures: ${WALF:-?}
  Failures this run         : $FAIL

(Immediate failure + WAL-pileup alerts also go to Slack/Alertmanager.)"
SUBJ="[Backup] $([ "$FAIL" -eq 0 ] && echo OK || echo FAILED) - $(date '+%Y-%m-%d')"
echo "$BODY" | "$BACKUP_ROOT/bin/send-mail.sh" "$SUBJ"
exit "$FAIL"
