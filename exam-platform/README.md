# Exam Platform - application code

    app/frontend/index.html   static frontend (S3 + CloudFront)
    app/api/                  Node/Express API (container for ECS Fargate)
    app/marker/handler.py     SQS-triggered Lambda that auto-marks MCQs
    docker-compose.yml        local test stack
    infra/                    Terraform (add your IaC here)
    architecture/ docs/ evidence/   assignment deliverables
    .github/workflows/        CI/CD

## Run locally
    docker compose up --build
    open http://localhost:8080
Autosave and question loading work locally. Submit (SQS) and upload (S3) need real AWS resources.

## Environment variables (API)
PGHOST, PGUSER, PGPASSWORD, PGDATABASE, PGSSLMODE, UPLOAD_BUCKET, MARKING_QUEUE_URL, AWS_REGION

## Deploy notes
- Build the API image, push to ECR, run on ECS Fargate behind the ALB.
- Run schema.sql then seed.sql once against RDS (private DB: use an SSM session or a one-off ECS task).
- Package the Lambda (build on Linux x86_64, or use a layer for psycopg2):
  cd app/marker && pip install -r requirements.txt -t pkg && cp handler.py pkg && cd pkg && zip -r ../marker.zip .
- Upload app/frontend/index.html to the frontend S3 bucket. CloudFront: /api/* -> ALB, default -> S3.
- Auth is stubbed with an x-user-id header for the demo. Production: Cognito JWT validation.
