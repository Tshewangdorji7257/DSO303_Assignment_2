"""One-off Lambda (runs inside the VPC) that loads schema.sql and seed.sql into the private RDS."""
import json
import os

import boto3
import psycopg2

HERE = os.path.dirname(__file__)


def handler(event, context):
    s = json.loads(boto3.client("secretsmanager").get_secret_value(
        SecretId=os.environ["PG_SECRET_ARN"])["SecretString"])
    conn = psycopg2.connect(
        host=os.environ["PGHOST"], user=s["username"], password=s["password"],
        dbname=os.environ["PGDATABASE"], sslmode="require")
    try:
        with conn, conn.cursor() as cur:
            cur.execute(open(os.path.join(HERE, "schema.sql")).read())
            cur.execute("SELECT COUNT(*) FROM exams")
            if cur.fetchone()[0] == 0:  # seed only once
                cur.execute(open(os.path.join(HERE, "seed.sql")).read())
    finally:
        conn.close()
    return {"initialised": True}
