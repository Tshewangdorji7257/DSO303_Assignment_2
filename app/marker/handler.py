import json
import os
import psycopg2


def handler(event, context):
    """SQS-triggered: auto-mark MCQs and store the score."""
    conn = psycopg2.connect(
        host=os.environ["PGHOST"], user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"], dbname=os.environ["PGDATABASE"],
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
