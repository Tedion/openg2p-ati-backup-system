#!/bin/bash
# Runs on the PG host via root cron (every 5 min). Pushes WAL-pileup health metrics so the
# cluster alerts before a disk-full prod outage. Reads PG_INSTANCE/PG_DATA/PUSHGATEWAY from
# a small local copy of backup.env on the PG host (only those 3 vars are needed here).
. /opt/backup/backup.env
PG="$PUSHGATEWAY/metrics/job/pg-wal/instance/$PG_INSTANCE"
WAL_BYTES=$(du -sb "$PG_DATA/pg_wal" 2>/dev/null | cut -f1)
STATS=$(sudo -u postgres psql -tAc "select failed_count||' '||coalesce(round(extract(epoch from now()-last_archived_time))::text,'-1') from pg_stat_archiver;" 2>/dev/null)
FAILED=$(echo "$STATS" | awk '{print $1}'); AGE=$(echo "$STATS" | awk '{print $2}')
printf 'pg_wal_size_bytes %s\npg_archiver_failed_count %s\npg_archiver_last_archive_age_seconds %s\n' \
  "${WAL_BYTES:-0}" "${FAILED:-0}" "${AGE:--1}" | curl -s --data-binary @- "$PG"
# NOTE: the cluster pushgateway does NOT honor pushed labels -> these arrive as
#       exported_instance="$PG_INSTANCE", exported_job="pg-wal".
#       Alert rules MUST select exported_instance/exported_job (see monitoring/).
