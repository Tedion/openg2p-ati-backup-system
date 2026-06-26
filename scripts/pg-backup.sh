#!/bin/bash
# pgBackRest backup runner. Arg = backup type (diff|full). Runs as $BACKUP_USER.
. /opt/backup/backup.env
export HOME="/home/$BACKUP_USER" PATH=/usr/local/bin:/usr/bin:/bin
TYPE="${1:-diff}"
PG="$PUSHGATEWAY/metrics/job/backup/instance/$BACKUP_INSTANCE"
if ionice -c2 -n7 nice -n19 pgbackrest --stanza="$PG_STANZA" --type="$TYPE" backup; then ST=1; else ST=0; fi
printf 'backup_status{backup_type="db"} %s\n' "$ST" | curl -s --data-binary @- "$PG/kind/db"
[ "$ST" -eq 1 ] && printf 'db_backup_last_success_timestamp %s\n' "$(date +%s)" | curl -s --data-binary @- "$PG/kind/dbsuccess"
[ "$ST" -eq 0 ] && echo "pgBackRest $TYPE backup FAILED on $BACKUP_INSTANCE at $(date). Check journalctl -u backup-pg@$TYPE and pgbackrest --stanza=$PG_STANZA info." | "$BACKUP_ROOT/bin/send-mail.sh" "[Backup] DB pgBackRest FAILED"
exit 0
