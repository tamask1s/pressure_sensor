import logging, os, smtplib, ssl, threading
from email.message import EmailMessage
from .common import *
log=logging.getLogger('pressure.mail')
def deliver(payload):
    message=EmailMessage(); message['From']=f"Talajnyomás <{os.environ['PRESSURE_MAIL_FROM']}>"; message['To']=payload['to']; message['Subject']=payload['subject']; message.set_content(payload['body'])
    with smtplib.SMTP(os.environ.get('PRESSURE_SMTP_HOST','127.0.0.1'),int(os.environ.get('PRESSURE_SMTP_PORT','25')),timeout=15) as smtp:
        if os.environ.get('PRESSURE_SMTP_TLS')=='1': smtp.starttls(context=ssl.create_default_context())
        if os.environ.get('PRESSURE_SMTP_USER'): smtp.login(os.environ['PRESSURE_SMTP_USER'],Path(os.environ['PRESSURE_SMTP_PASSWORD_FILE']).read_text().strip())
        smtp.send_message(message)
def work(stop):
    while not stop.wait(5):
        try:
            with connect() as db: row=one(db,'SELECT * FROM outbox WHERE next_try<=? ORDER BY id LIMIT 1',(now(),))
            if not row: continue
            deliver(obj(unseal(row['payload'])))
            with connect(True) as db: db.execute('DELETE FROM outbox WHERE id=?',(row['id'],))
        except Exception:
            log.warning('Email delivery failed; queued retry (no recipient/token logged)')
            if 'row' in locals() and row:
                try:
                    with connect(True) as db:
                        if row['attempts']>=20: db.execute('DELETE FROM outbox WHERE id=?',(row['id'],))
                        else: db.execute('UPDATE outbox SET attempts=attempts+1,next_try=? WHERE id=?',(now()+min(3600,30*2**min(row['attempts'],7)),row['id']))
                except Exception: log.warning('Outbox update failed')
