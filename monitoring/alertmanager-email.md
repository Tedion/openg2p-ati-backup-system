# Adding an email route to Alertmanager (kube-prometheus-stack)

Backup alerts (`component="backup"`) should route to **both Slack and email**.
Config lives in the secret `alertmanager-<release>-alertmanager` (key `alertmanager.yaml`).
Mount your SMTP + Slack secrets on the Alertmanager pod (`spec.secrets` on the Alertmanager CR).

## What to add

**1. `global:` SMTP settings** (Gmail app password = strip spaces):
```yaml
global:
  smtp_smarthost: smtp.gmail.com:587
  smtp_from: alerts@example.org
  smtp_auth_username: alerts@example.org
  smtp_auth_password: <APP_PASSWORD_NO_SPACES>
  smtp_require_tls: true
```

**2. A receiver:**
```yaml
receivers:
- name: backup-email
  email_configs:
  - to: ops-team@example.org
    send_resolved: true
```

**3. A top route (continue:true so backup alerts ALSO go to email, then continue to Slack):**
```yaml
route:
  routes:
  - matchers:
    - component = "backup"
    receiver: backup-email
    continue: true
  - ...existing severity routes...
```

## Apply safely

```bash
SECRET=alertmanager-<release>-alertmanager
AMPOD=alertmanager-<release>-alertmanager-0

# 1. back up
kubectl -n monitoring get secret $SECRET -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d > am-backup.yaml
# 2. edit -> am-new.yaml ; VALIDATE (pod fs is read-only -> use /dev/shm)
kubectl -n monitoring exec -i $AMPOD -c alertmanager -- \
  sh -c 'cat > /dev/shm/c.yaml && amtool check-config /dev/shm/c.yaml; rm -f /dev/shm/c.yaml' < am-new.yaml
# 3. confirm routing
kubectl -n monitoring exec -i $AMPOD -c alertmanager -- \
  sh -c 'cat > /dev/shm/c.yaml && amtool config routes test --config.file=/dev/shm/c.yaml --tree component=backup severity=critical' < am-new.yaml
#   expected: backup-email, slack-critical
# 4. apply
kubectl -n monitoring patch secret $SECRET --type merge \
  -p "{\"data\":{\"alertmanager.yaml\":\"$(base64 -w0 am-new.yaml)\"}}"
# if the pod goes un-Ready, restore am-backup.yaml the same way.
```
