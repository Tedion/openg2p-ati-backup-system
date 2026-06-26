#!/bin/bash
# Email helper. Usage:  echo "body" | send-mail.sh "subject"
# Reads SMTP settings from /opt/backup/.smtp (640 root:$BACKUP_USER). See config/smtp.env.example.
# NOTE: body is read into a var first, then passed via env. Do not use `python3 - <<'PY'`,
#       that makes the heredoc the program's stdin and the body is lost (empty-body bug).
set -a; . /opt/backup/.smtp 2>/dev/null; set +a
SUBJECT="$1"
BODY="$(cat)"
export SUBJECT BODY
python3 -c '
import smtplib, ssl, os
from email.message import EmailMessage
m = EmailMessage()
m["Subject"] = os.environ["SUBJECT"]; m["From"] = os.environ["SMTP_FROM"]; m["To"] = os.environ["MAIL_TO"]
m.set_content(os.environ.get("BODY", ""))
try:
    s = smtplib.SMTP(os.environ["SMTP_HOST"], int(os.environ["SMTP_PORT"]), timeout=25)
    s.starttls(context=ssl.create_default_context())
    s.login(os.environ["SMTP_USER"], os.environ["SMTP_PASS"]); s.send_message(m); s.quit()
    print("MAIL_SENT")
except Exception as e:
    import sys; sys.stderr.write("mail fail: %r\n" % e); sys.exit(1)
'
