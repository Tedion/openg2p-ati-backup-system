# OpenG2P Backup and Restore System

Backup tooling for an OpenG2P production cluster. A dedicated host pulls backups from every data store, keeps them encrypted and retained, monitors that they ran, and alerts when they do not. It uses the same tools as the [OpenG2P backup reference](https://docs.openg2p.org/operations/deployment/infrastructure-setup/backups/architecture) but ships its own orchestration so it works on any on-prem layout.

Treat this as something you operate, not something you install once. Backups have to keep running, you have to watch that they run, and you have to test the restores.

## Overview

One backup host pulls from production and stores:

* PostgreSQL with pgBackRest (continuous WAL archiving for point-in-time recovery, plus daily differentials)
* etcd from the cluster's native RKE2 snapshots, repacked into an encrypted restic repo
* Kubernetes resources (secrets, configmaps, manifests) with the rancher-backup operator
* The NFS filesystem with restic
* The MinIO object store with `mc mirror`

systemd timers run the jobs, each job reports a metric to Prometheus through the Pushgateway, and Alertmanager sends failures to Slack and email. A dead-man's switch fires if a backup stops running at all. Nothing site-specific is hard-coded; every IP, host, user, and path lives in `config/backup.env`.

## Architecture

The backup host opens every connection itself and reads from production. Production never writes to the backup host, so a compromised or misbehaving prod node cannot delete the backups. Run the backup host on different hardware and a different storage pool from the cluster, otherwise one storage failure takes down production and its backups at the same time.

```
  PRODUCTION                              BACKUP HOST  (separate pool)
  ----------                              ------------
  NFS server      --- restic pull ------> /opt/backup/restic/nfs        encrypted, deduped
  MinIO           --- mc mirror --------> /opt/backup/minio-mirror      object copy
  PostgreSQL      --- pgBackRest WAL ---> /opt/backup/pgbackrest        encrypted, PITR
  etcd snapshots  --- scp -------------> /opt/backup/etcd-snapshots --> restic/etcd  (encrypted)
  rancher-backup  --- writes to PVC ----> nfs-csi volume, picked up by the NFS restic job

                         metrics  v
                  Prometheus Pushgateway
                                 |
              PrometheusRule -> Alertmanager -> Slack + email
```

| Store        | Tool          | Reason                                                          |
|--------------|---------------|----------------------------------------------------------------|
| PostgreSQL   | pgBackRest    | WAL archiving gives point-in-time recovery; parallel, AES-256  |
| etcd         | RKE2 + restic | RKE2 takes a consistent snapshot; restic adds encryption       |
| K8s objects  | rancher-backup| Captures secrets, configmaps, PVCs and CRDs as a restore set   |
| NFS          | restic        | Dedup and compression keep incrementals cheap                  |
| MinIO        | mc mirror     | Native incremental object sync; objects rarely compress        |

This uses OpenG2P's tools but not their installer. The upstream `openg2p-backup.sh` assumes AWS (EBS, IMDS) and a fixed three-node layout. This version makes no assumption about topology.

## Layout

```
openg2p-ati-backup-system/
  README.md
  install.sh                          renders and deploys everything from backup.env
  config/
    backup.env.example                the one file you edit
    smtp.env.example
    pgbackrest-repohost.conf.example
    pgbackrest-pghost.conf.example
  scripts/                            all read /opt/backup/backup.env
    master-backup.sh  pg-backup.sh  etcd-restic.sh
    integrity-check.sh  send-mail.sh  pg-wal-health.sh
  systemd/                            service and timer units
  monitoring/
    prometheusrule.yaml.template      placeholders rendered by install.sh
    alertmanager-email.md
```

## Setup

Everything site-specific is in one file. On the backup host, as root:

```bash
git clone <this-repo> && cd openg2p-ati-backup-system

cp config/backup.env.example  /opt/backup/backup.env   # edit: IPs, hosts, users
cp config/smtp.env.example    /opt/backup/.smtp        # edit: SMTP creds, recipient

sudo ./install.sh
```

`install.sh` copies the scripts, renders the systemd units and the Prometheus rule from `backup.env`, enables the timers, and prints the manual steps that need a human: restic repo init, the `mc` alias, the pgBackRest stanza and `archive_mode`, where to ship etcd snapshots, and the monitoring apply. You do not edit any code.

## Operations

```bash
systemctl start backup-master.service          # run NFS + MinIO now, send a summary email
/opt/backup/bin/pg-backup.sh full              # ad-hoc full DB backup
restic -r /opt/backup/restic/nfs snapshots     # what is in the repo
pgbackrest --stanza=<stanza> info
kubectl -n cattle-resources-system get backups
systemctl list-timers 'backup-*'
/opt/backup/bin/integrity-check.sh             # also runs weekly
```

## Monitoring and alerting

Each job pushes a metric to the Pushgateway (job `backup` or `pg-wal`). A PrometheusRule reads those metrics and routes alerts to Slack and email.

One thing to watch when you copy the rules: this cluster's Pushgateway does not honor pushed labels, so a metric pushed with `instance` and `job` arrives in Prometheus as `exported_instance` and `exported_job`. The rules select on the `exported_` versions. Keep that or the alerts will silently match nothing.

| Alert                            | Fires when                                       |
|----------------------------------|--------------------------------------------------|
| `BackupRunMissed`                | no successful backup in over 26h (dead-man's switch) |
| `BackupSourceFailed` / `BackupRunFailed` | a source failed this run                  |
| `BackupDiskLow` / `Critical`     | the backup host is low on space                  |
| `WALArchiveStalled` / `Failing`  | WAL is not being archived, which fills the prod disk |
| `WALDirGrowing` / `Critical`     | pg_wal is getting too large                      |
| `*MetricsAbsent`                 | metrics stopped arriving                         |

Email goes out as one daily summary, plus an immediate message on any failure, plus the Alertmanager alerts above.

## Restore

Always restore to a scratch target, never over a live store.

```bash
# NFS, a single file or the whole tree
restic -r /opt/backup/restic/nfs restore latest --target /restore [--include /path]

# etcd, then on the master: rke2 server --cluster-reset --cluster-reset-restore-path=<snap>
restic -r /opt/backup/restic/etcd restore latest --target /restore

# PostgreSQL point-in-time, onto a scratch or standby instance
pgbackrest --stanza=<stanza> --type=time "--target=YYYY-MM-DD HH:MM:SS" restore

# MinIO
mc mirror /opt/backup/minio-mirror/<bucket> <alias>/<bucket>

# Kubernetes resources: create a Restore CR that references the rancher-backup filename
```

## Recovery objectives

| Component   | RPO                  | RTO            | Notes                          |
|-------------|----------------------|----------------|--------------------------------|
| PostgreSQL  | minutes (WAL / PITR) | 30 to 60 min   | depends on WAL replay distance |
| etcd        | 6h                   | about 15 min   | RKE2 cluster-reset restore     |
| NFS         | 24h                  | minutes to hrs | per-file or full               |
| MinIO       | 24h                  | hours          | mc mirror back                 |
| K8s objects | 24h                  | minutes        | rancher-backup Restore CR      |

## Limitations

* One copy by default. Add a second or off-site copy (a weekly push to shared storage works) to satisfy 3-2-1.
* MinIO is stored unencrypted. The objects are already-compressed binaries, so encrypting them adds nothing but disk.
* Restores assume the target cluster has the same topology.
* The weekly integrity check is automatic. A full disaster-recovery rehearsal is still a manual exercise.

## Things that will bite you

These are the failure modes worth knowing before you deploy.

* Keep the backup host off the production hypervisor and storage pool. If they share a pool, one failure loses both.
* Turning on `archive_mode` requires a Postgres restart. Before that restart, run `pgbackrest archive-push` against an existing WAL file and confirm it succeeds. If `archive_command` is wrong when archiving turns on, WAL accumulates, the disk fills, and Postgres stops.
* The Pushgateway relabels pushed metrics to `exported_instance` and `exported_job`. Select on those.
* `pg_wal_size_bytes` is also a metric name used by postgres-exporter. Disambiguate with the `exported_` labels.
* Gmail app passwords are printed with spaces. Strip them before use.
* In `send-mail.sh`, read the body into a variable first. Do not feed the program through a heredoc on stdin, or the body is lost.
* To validate an Alertmanager config inside the pod, write it to `/dev/shm`. The pod filesystem is read-only.

## References

[pgBackRest](https://pgbackrest.org/), [restic](https://restic.net/), [RKE2 backup and restore](https://docs.rke2.io/backup_restore), [rancher-backup](https://ranchermanager.docs.rancher.com/integrations-in-rancher/backup-restore-and-disaster-recovery), [MinIO mc mirror](https://min.io/docs/minio/linux/reference/minio-mc/mc-mirror.html), [OpenG2P backup reference](https://docs.openg2p.org/operations/deployment/infrastructure-setup/backups/architecture).
