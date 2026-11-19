# Deployment evidence: Online Exam Platform on AWS

All screenshots were taken in AWS account `363242104805`, region **us-east-1 (N. Virginia)**. The live site was https://d2kt7z67ovmegb.cloudfront.net.
Every resource was created by Terraform through the GitHub Actions pipeline. Nothing was built by hand in the console.

Contents
1. [Local test](#1-local-test)
2. [Bootstrap and GitHub configuration](#2-bootstrap-and-github-configuration)
3. [CI/CD pipeline (IaC)](#3-cicd-pipeline-iac)
4. [Frontend and edge layer](#4-frontend-and-edge-layer)
5. [Walkthrough 1: open exam, autosave, auto-marking](#5-walkthrough-1-open-exam-autosave-auto-marking)
6. [Walkthrough 2: 40 MB-style upload and tutor notification](#6-walkthrough-2-upload-and-tutor-notification)
7. [Two Availability Zones and security](#7-two-availability-zones-and-security)
8. [Monitoring](#8-monitoring)

---

## 1. Local test

The app stack (PostgreSQL, API and frontend) was built and run with Docker Compose before deploying.

![alt text](../evidence/image.png)

The app running locally on http://localhost:8081:

![alt text](../evidence/image-15.png)
![alt text](../evidence/image-1.png)

## 2. Bootstrap and GitHub configuration

**GitHub repository created**

![alt text](../evidence/image-2.png)

**Terraform validated** (`terraform init` / `terraform validate`)

![alt text](../evidence/image-3.png)
![alt text](../evidence/image-4.png)

**AWS access checked**, to confirm the CLI identity and permissions

![alt text](../evidence/image-7.png)
![alt text](../evidence/image-5.png)
![alt text](../evidence/image-6.png)

**Region setting checked** (`us-east-1`)

![alt text](../evidence/image-8.png)

**Bootstrap** (`infra/bootstrap`) creates the Terraform state bucket and the GitHub OIDC deploy role. Existing resources were imported first.

State bucket imported:

![alt text](../evidence/image-9.png)

GitHub OIDC provider imported:

![alt text](../evidence/image-10.png)

Verify:

![alt text](../evidence/image-11.png)

Apply:

![alt text](../evidence/image-12.png)

Verify:

![alt text](../evidence/image-13.png)

**GitHub Actions settings.** The repository secret `AWS_ROLE_ARN` holds the deploy role. The repository variables are `TF_STATE_BUCKET`, `ALERT_EMAIL` and `NOTIFY_EMAIL`. No AWS access keys are stored anywhere.

![alt text](../evidence/image-16.png)
![alt text](../evidence/image-17.png)

## 3. CI/CD pipeline (IaC)

A push to `main` runs `.github/workflows/deploy.yml`:
1. Assume the role through OIDC.
2. Build the Lambda package.
3. `terraform init` and `validate`.
4. Create ECR, then build and push the API image.
5. `terraform apply` for the full stack.
6. Sync the frontend to S3 and invalidate CloudFront.
7. Smoke test.

**E01. Green deploy run with every step ticked**

![alt text](../evidence/image-20.png)
![alt text](../evidence/image-25.png)

**E04. Smoke test: `ok Application health check passed!`**

![alt text](../evidence/image-22.png)

**E06. All infrastructure defined as code in `infra/`**

![alt text](../evidence/image-26.png)

## 4. Frontend and edge layer

**E07. Exam page served through CloudFront** (address bar shows the CloudFront domain)

![alt text](../evidence/image-21.png)
![alt text](../evidence/image-27.png)

**E08. CloudFront origins:** private S3 bucket through Origin Access Control, and the ALB for the API

![alt text](../evidence/image-28.png)
![alt text](../evidence/image-29.png)

**E09. CloudFront behaviours:** `/api/*` goes to the ALB with caching disabled; the default goes to S3

![alt text](../evidence/image-30.png)

**E10. AWS WAF on CloudFront:** a per-IP rate limit plus the AWS Common and Known Bad Inputs managed rule sets

![alt text](../evidence/image-31.png)

## 5. Walkthrough 1: open exam, autosave, auto-marking

Request path: Browser → CloudFront → WAF → ALB (CloudFront-only) → ECS Fargate task (private subnet, either AZ) → RDS PostgreSQL Multi-AZ.

**E11. Opening the exam:** `GET /api/exams/1` returns 200 with the questions (correct answers are never sent)

![alt text](../evidence/image-32.png)

**E12. Autosave every 30 s:** `PUT /api/exams/1/answers` returns 200 `{"saved":…}` (idempotent upsert in RDS)

![alt text](../evidence/image-33.png)

**E13. Submit, then result:** the API queues the job on SQS, the marker Lambda scores it, and the page shows *Your score: 3 of 4*

![alt text](../evidence/image-34.png)

**E14. SQS `exam-tsd-marking`:** messages sent and received

![alt text](../evidence/image-35.png)

**E15. Marker Lambda logs:** `Marked {...}: score=3` written to RDS `results`

![alt text](../evidence/image-36.png)

## 6. Walkthrough 2: upload and tutor notification

Request path: Browser → API (`/api/uploads/presign`) → presigned URL → **browser uploads directly to S3** → S3 event → SQS `notify` → notify Lambda → Amazon SES → tutor email.

**E16. Network tab:** `GET /api/uploads/presign`, then a `PUT` straight to `…s3.us-east-1.amazonaws.com`. The file never passes through the API.

![alt text](../evidence/image-37.png)

**E17. Upload confirmed in the app**

![alt text](../evidence/image-38.png)

**E18. Object stored in `exam-tsd-uploads-…-us-east-1/submissions/demo-student/`**

![alt text](../evidence/image-39.png)

**E19. Encryption at rest:** SSE-KMS with the customer-managed key

![alt text](../evidence/image-40.png)

**E20. Lifecycle `retain-5-years`:** Standard-IA after 30 days, Glacier after 180 days, expiry after 1,826 days

![alt text](../evidence/image-41.png)

**E21. Event notification:** `s3:ObjectCreated:*` on `submissions/` goes to the SQS notify queue

![alt text](../evidence/image-42.png)

**E22. Tutor email received:** "New assignment from demo-student"

![alt text](../evidence/image-43.png)

**E23. Notify Lambda logs:** the invocation that sent the email through SES

![alt text](../evidence/image-44.png)

## 7. Two Availability Zones and security

**E24. Six subnets across us-east-1a and us-east-1b:** public, private app and private data in each AZ

![alt text](../evidence/image-45.png)

**E25. One NAT gateway per AZ**, so losing one AZ does not cut outbound access for the other

![alt text](../evidence/image-46.png)

**E26. Database route table:** only the `local` route, with no path to the internet

![alt text](../evidence/image-47.png)

**E27. RDS `exam-tsd-db`:** Multi-AZ **Yes**, storage encrypted with KMS, publicly accessible **No**

![alt text](../evidence/image-48.png)

**E28. RDS primary and standby in different AZs**

![alt text](../evidence/image-49.png)
![alt text](../evidence/image-50.png)

**E29. ECS Fargate:** 2 running API tasks spread across both AZs

![alt text](../evidence/image-51.png)

**E30. ALB target group:** both targets healthy

![alt text](../evidence/image-52.png)

**E31. Database security group:** port 5432 only from the API and Lambda security groups

![alt text](../evidence/image-53.png)

**E32. Secrets Manager:** the RDS-managed master secret, injected into ECS and Lambda at runtime (no passwords in code)

![alt text](../evidence/image-54.png)

## 8. Monitoring

**E33. CloudWatch dashboard `exam-tsd`:** ALB requests and 5xx, ECS CPU, RDS CPU and connections, marking queue depth

![alt text](../evidence/image-55.png)

**E34. CloudWatch alarms:** ALB 5xx, unhealthy targets, RDS CPU, and both DLQs, sent to SNS email

![alt text](../evidence/image-56.png)