import json
import os

import boto3
import psycopg2

_creds = None


def _db_creds():
    """Read DB username/password from Secrets Manager once per Lambda container."""
    global _creds
    if _creds is None:
        secret = boto3.client("secretsmanager").get_secret_value(
            SecretId=os.environ["PG_SECRET_ARN"])["SecretString"]
        _creds = json.loads(secret)
    return _creds


def handler(event, context):
    """SQS-triggered: auto-mark MCQs and store the score."""
    creds = _db_creds()
    conn = psycopg2.connect(
        host=os.environ["PGHOST"], user=creds["username"],
        password=creds["password"], dbname=os.environ["PGDATABASE"],
        sslmode=os.environ.get("PGSSLMODE", "require"))
    try:
        for record in event["Records"]:
            msg = json.loads(record["body"])
            with conn, conn.cursor() as cur:
                cur.execute(
                    """SELECT COUNT(*) FROM answers a
                       JOIN questions q ON q.id = a.question_id
                       WHERE a.student_id=%s AND a.exam_id=%s AND a.answer = q.correct""",
                    (msg["studentId"], msg["examId"]))
                score = cur.fetchone()[0]
                cur.execute(
                    """INSERT INTO results (student_id, exam_id, score) VALUES (%s,%s,%s)
                       ON CONFLICT (student_id, exam_id) DO UPDATE SET score=EXCLUDED.score""",
                    (msg["studentId"], msg["examId"], score))
            print(f"Marked {msg}: score={score}")
    finally:
        conn.close()
    return {"processed": len(event["Records"])}