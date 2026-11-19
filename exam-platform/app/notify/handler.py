"""SQS-triggered: emails the tutor when an assignment lands in S3, and when results are released."""
import json
import os
from urllib.parse import unquote_plus

import boto3

ses = boto3.client("ses")


def send(subject, text):
    ses.send_email(
        Source=os.environ["SENDER"],
        Destination={"ToAddresses": [os.environ["TUTOR_EMAIL"]]},
        Message={"Subject": {"Data": subject}, "Body": {"Text": {"Data": text}}})


def handler(event, context):
    for record in event["Records"]:
        body = json.loads(record["body"])
        if "Records" in body:  # S3 ObjectCreated notification
            for r in body["Records"]:
                key = unquote_plus(r["s3"]["object"]["key"])
                size_mb = r["s3"]["object"].get("size", 0) / 1024 / 1024
                student = key.split("/")[1] if "/" in key else "unknown"
                send(f"New assignment from {student}",
                     f"File: {key}\nSize: {size_mb:.1f} MB\nBucket: {r['s3']['bucket']['name']}")
        elif body.get("type") == "results_released":
            send(f"Results released for exam {body['examId']}",
                 "Results are now available to students.")
        # anything else (e.g. the s3:TestEvent) is ignored
    return {"processed": len(event["Records"])}
