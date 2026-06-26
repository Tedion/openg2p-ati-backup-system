#!/bin/bash
# Install the backup system on the backup host. Run as root from the repo root.
#   1. cp config/backup.env.example /opt/backup/backup.env  &&  edit it
#   2. cp config/smtp.env.example   /opt/backup/.smtp        &&  edit it
#   3. sudo ./install.sh
set -e
CONF=/opt/backup/backup.env
[ -f "$CONF" ] || { echo "Create $CONF first (cp config/backup.env.example $CONF and edit)"; exit 1; }
. "$CONF"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo ">> directories"
mkdir -p "$BACKUP_ROOT"/{bin,restic,restic/cache,minio-mirror,etcd-snapshots,pgbackrest,logs}
mountpoint -q "$NFS_MOUNT" 2>/dev/null || mkdir -p "$NFS_MOUNT"

echo ">> scripts -> $BACKUP_ROOT/bin"
install -m 0755 "$HERE"/scripts/*.sh "$BACKUP_ROOT/bin/"

echo ">> secrets (generate restic passphrases if missing, then store them in your vault)"
for r in nfs etcd; do
  f="$BACKUP_ROOT/restic/.$r-pass"
  [ -s "$f" ] || { umask 077; openssl rand -base64 24 > "$f"; echo "   generated $f"; }
done

echo ">> .smtp perms"
[ -f "$BACKUP_ROOT/.smtp" ] && { chown root:"$BACKUP_USER" "$BACKUP_ROOT/.smtp"; chmod 640 "$BACKUP_ROOT/.smtp"; }
chown root:"$BACKUP_USER" "$CONF"; chmod 640 "$CONF"

echo ">> systemd units (render backup user)"
for u in "$HERE"/systemd/*; do
  sed "s/__BACKUP_USER__/$BACKUP_USER/g" "$u" > "/etc/systemd/system/$(basename "$u")"
done
systemctl daemon-reload
systemctl enable --now backup-master.timer backup-pg-diff.timer backup-etcd-restic.timer backup-integrity.timer

echo ">> rendered PrometheusRule -> ./monitoring/prometheusrule.rendered.yaml"
sed -e "s/__BACKUP_INSTANCE__/$BACKUP_INSTANCE/g" -e "s/__PG_INSTANCE__/$PG_INSTANCE/g" \
    "$HERE/monitoring/prometheusrule.yaml.template" > "$HERE/monitoring/prometheusrule.rendered.yaml"

echo ""
echo "DONE. Remaining manual steps:"
echo "  - restic repos:   restic -r $BACKUP_ROOT/restic/{nfs,etcd} init   (with the passfiles)"
echo "  - mc alias:       mc alias set $MINIO_ALIAS $MINIO_ENDPOINT <KEY> <SECRET>"
echo "  - pgBackRest:     configs/pgbackrest-*.conf on PG + backup host; enable archive_mode (PG restart); stanza-create; first full"
echo "  - etcd:           point the cluster snapshot job to scp tarballs into $BACKUP_ROOT/etcd-snapshots on this host"
echo "  - pg-wal-health:  copy scripts/pg-wal-health.sh + a minimal backup.env to the PG host; cron every 5 min"
echo "  - monitoring:     kubectl apply -f monitoring/prometheusrule.rendered.yaml  + add the Alertmanager email route (monitoring/alertmanager-email.md)"
echo "  - timers active:  systemctl list-timers 'backup-*'"
