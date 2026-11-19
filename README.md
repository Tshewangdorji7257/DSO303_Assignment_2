# DSO303 Assignment 2: Architecture Design and Deployment

**Repository:** https://github.com/Tshewangdorji7257/DSO303_Assignment_2
**Live demo (during assessment):** https://d2kt7z67ovmegb.cloudfront.net
**AWS region:** us-east-1 (N. Virginia)

---

## 1. Aim / Objective

To design, document and deploy a highly available, secure AWS architecture for a university online exam and assignment platform. The objectives are:

1. **Design.** Draw a full production architecture across two Availability Zones: edge (DNS, CDN, WAF), frontend, API and compute, authentication, database, file storage with lifecycle rules, asynchronous marking and email, monitoring, secrets and CI/CD.
2. **Document.** Justify every AWS service against an alternative and give its configuration.
3. **Implement as code.** Build the architecture with Terraform, deploy it automatically from GitHub Actions on every push to `main`, and show both user walkthroughs (exam with autosave, and assignment upload with tutor notification) working end to end.
4. **Meet the targets:**
   - 99.9% availability during exams
   - survive the loss of one AZ
   - RPO 5 minutes and RTO 1 hour
   - 5-year retention
   - encryption in transit and at rest

## 2. Introduction

Amazon Web Services (AWS) provides managed building blocks that let a small team run a system that would otherwise need a data centre and an operations team.

This practical combines a set of AWS services into one three-tier application:

- **Amazon CloudFront** and **AWS WAF** at the edge
- **Amazon S3** for static hosting and file storage
- an **Application Load Balancer** with **Amazon ECS on AWS Fargate** for the containerised API
- **Amazon RDS for PostgreSQL (Multi-AZ)** for exam data
- **Amazon SQS**, **AWS Lambda** and **Amazon SES** for background marking and email
- **AWS KMS** and **AWS Secrets Manager** for encryption and credentials
- **Amazon CloudWatch** and **Amazon SNS** for monitoring

Their main strengths are managed high availability (Multi-AZ databases and load balancers), elastic scaling (Fargate auto scaling, Lambda), pay-per-use pricing and built-in security (IAM, KMS, TLS).

In cloud computing, these managed services let you build systems that are **highly available, scalable and secure by design**. Combined with **Infrastructure as Code** (Terraform) and **CI/CD** (GitHub Actions with OIDC), the whole environment can be rebuilt from a Git repository. Typical uses are web and mobile back ends, e-learning and exam platforms, e-commerce sites, and any workload with sharp traffic peaks.

## 3. Use Case

**Scenario.** A university with 8,000 students and about 400 staff is moving all exams and assignment submissions online.

| User | Needs |
|---|---|
| Students | Sit timed MCQ and short-answer exams with answers autosaved every 30 s; upload assignments (PDF/ZIP, up to 50 MB) |
| Tutors | Create exams, mark, release results; get notified of uploads |
| Administrators | Manage users and schedules |

**Load.** Normally 300–500 concurrent users. At exam-week peak, **3,000 students start one exam within 5 minutes**.

Where each service fits in this use case:

- **Amazon CloudFront + S3** serve the exam web app to thousands of students at once from edge locations.
- **ECS Fargate behind an ALB** runs the exam API and scales out for the 5-minute burst.
- **RDS PostgreSQL Multi-AZ** stores exams, autosaved answers and results without losing committed data if an AZ fails.
- **S3 with presigned URLs** takes 50 MB uploads directly from the browser and keeps them 5 years with lifecycle rules.
- **SQS + Lambda** auto-marks MCQs in the background so a wave of submissions cannot overload the database.
- **S3 events + SQS + Lambda + SES** emails the tutor when an assignment arrives.
- **Cognito** provides role-based sign-in for students, tutors and admins.
- **CloudWatch + SNS** alert the operations team during exam week.

## 4. System Architecture / Design

![AWS architecture diagram](<architecture/aws-architecture-diagram (11).png>)

**Network layout.** VPC `10.0.0.0/16` in **us-east-1a** and **us-east-1b**. Each AZ has:
- a **public subnet** (ALB node, NAT gateway)
- a **private app subnet** (Fargate tasks, Lambdas)
- a **private data subnet** (RDS, with no route to the internet)

**Data flow summary:**

| Flow | Path |
|---|---|
| Static site | User → Route 53 → CloudFront (+ WAF) → S3 frontend bucket (Origin Access Control) |
| API | CloudFront `/api/*` → ALB (CloudFront prefix list + secret origin header only) → ECS Fargate (2 AZs) → RDS Multi-AZ (TLS, credentials from Secrets Manager) |
| Exam submit | API → SQS `marking` → Lambda marker → RDS `results` (DLQ after 5 failures) |
| Upload | API returns presigned URL → browser `PUT` straight to S3 uploads (SSE-KMS) → S3 event → SQS `notify` → Lambda → SES email to tutor |
| Monitoring | CloudWatch alarms (ALB 5xx, unhealthy targets, RDS CPU, DLQ depth) → SNS email; CloudWatch dashboard |
| Delivery | `git push` → GitHub Actions → OIDC role → Terraform (S3 remote state) → ECR → ECS / S3 / CloudFront |

The detailed walkthroughs and the explanation of how the design handles the exam peak and the loss of one AZ are in [`architecture/walkthroughs.md`](architecture/walkthroughs.md). Every service is justified against an alternative in [`docs/services.md`](docs/services.md).

## 5. Implementation Procedure

1. **Test the application locally.**
   - Ran `docker compose up --build` to start PostgreSQL, the API and the frontend.
   - Checked that questions load and autosave works on `http://localhost:8081`.
2. **Write the infrastructure as code.** Terraform in `infra/`, split by layer:
   - `network.tf`: VPC, 6 subnets, IGW, 2 NAT gateways, route tables, S3 endpoint, security groups
   - `edge.tf`: WAF, CloudFront with S3 and ALB origins
   - `compute.tf`: ECR, ECS cluster and service, ALB, IAM roles, auto scaling
   - `data.tf`: KMS, RDS Multi-AZ, S3 buckets with lifecycle, CORS and events, Cognito
   - `async.tf`: SQS queues and DLQs, Lambda marker, notify and db-init, SES
   - `monitoring.tf`: SNS, CloudWatch alarms, dashboard
3. **Validate.** Ran `terraform fmt` and `terraform validate`.
4. **Bootstrap (one-time).** `infra/bootstrap` creates:
   - the versioned, encrypted S3 bucket for Terraform state
   - an IAM role that GitHub Actions can assume through the account's GitHub OIDC provider

   ```bash
   terraform apply -var="region=us-east-1" -var="project=exam-tsd" \
     -var="github_repo=Tshewangdorji7257/DSO303_Assignment_2"
   ```
5. **Configure GitHub.**
   - Secret: `AWS_ROLE_ARN`
   - Variables: `TF_STATE_BUCKET`, `ALERT_EMAIL`, `NOTIFY_EMAIL`
   - No AWS access keys are stored.
6. **Write the pipeline** (`.github/workflows/deploy.yml`). On every push to `main` it:
   1. assumes the role via OIDC
   2. builds the Lambda package
   3. runs `terraform init` and `validate`
   4. creates ECR, then builds and pushes the API image tagged with the commit SHA
   5. runs `terraform apply` for the full stack (a `db_init` Lambda loads the schema and seed data into the private RDS)
   6. syncs the frontend to S3 and invalidates CloudFront
   7. smoke-tests `/api/health`
7. **Deploy.** Pushed to `main`, then fixed the problems found (see Section 7) until the pipeline was green.
8. **Confirm notifications.** Clicked the SNS subscription link and the SES verification link.
9. **Test both walkthroughs** on the live site and collected the evidence (Section 6).
10. **Tear down.** After assessment, ran `terraform destroy` for the stack, then the bootstrap (steps in [`README.md`](README.md)).

## 6. Results and Evidence

The full evidence set, with captions, is in [`evidence/README.md`](evidence/README.md). The key screenshots are below.

### 6.1 CLI / SDK Output

**Local Docker build and test.** The application stack builds and runs locally.

![alt text](evidence/image.png)
![alt text](evidence/image-15.png)

**Terraform validate.** The configuration is valid.

![alt text](evidence/image-3.png)
![alt text](evidence/image-4.png)

**AWS CLI identity and access check.** Confirms the account and permissions used for the bootstrap.

![alt text](evidence/image-7.png)
![alt text](evidence/image-5.png)

**Bootstrap.** Imported the existing state bucket and OIDC provider, then applied.

![alt text](evidence/image-9.png)
![alt text](evidence/image-10.png)
![alt text](evidence/image-12.png)
![alt text](evidence/image-13.png)

**GitHub Actions pipeline.** A push to `main` deploys the whole stack automatically, and every step is green.

![alt text](evidence/image-20.png)
![alt text](evidence/image-25.png)

**Smoke test.** `ok Application health check passed!`

![alt text](evidence/image-22.png)

### 6.2 AWS Management Console Verification

| # | Screenshot | One-line explanation |
|---|---|---|
| 1 | ![alt text](evidence/image-17.png) | GitHub Actions variables configured. The deploy role is assumed through OIDC, so no access keys are stored. |
| 2 | ![alt text](evidence/image-26.png) | All infrastructure is defined as Terraform code in `infra/`. |
| 3 | ![alt text](evidence/image-27.png) | The exam web app is served from S3 through CloudFront. |
| 4 | ![alt text](evidence/image-28.png) | CloudFront origins: the private S3 bucket (OAC) and the ALB. |
| 5 | ![alt text](evidence/image-30.png) | CloudFront behaviours: `/api/*` goes to the ALB (no cache); everything else goes to S3. |
| 6 | ![alt text](evidence/image-31.png) | WAF web ACL with a per-IP rate limit and AWS managed rule sets. |
| 7 | ![alt text](evidence/image-32.png) | Walkthrough 1: `GET /api/exams/1` loads the exam through CloudFront, ALB and Fargate. |
| 8 | ![alt text](evidence/image-33.png) | Walkthrough 1: autosave `PUT /api/exams/1/answers` every 30 s, stored in RDS. |
| 9 | ![alt text](evidence/image-34.png) | Submitting the exam queues a marking job; the result "3 of 4" is shown. |
| 10 | ![alt text](evidence/image-35.png) | The SQS `exam-tsd-marking` queue shows messages sent and received. |
| 11 | ![alt text](evidence/image-36.png) | The marker Lambda log shows the score written to RDS. |
| 12 | ![alt text](evidence/image-37.png) | Walkthrough 2: presigned URL, then the browser `PUT`s straight to S3, bypassing the API. |
| 13 | ![alt text](evidence/image-38.png) | The app confirms the upload. |
| 14 | ![alt text](evidence/image-39.png) | The uploaded file is stored under `submissions/demo-student/`. |
| 15 | ![alt text](evidence/image-40.png) | The object is encrypted at rest with SSE-KMS (customer-managed key). |
| 16 | ![alt text](evidence/image-41.png) | Lifecycle rule: Standard-IA at 30 days, Glacier at 180 days, expiry at 5 years. |
| 17 | ![alt text](evidence/image-42.png) | An S3 `ObjectCreated` event sends a message to the SQS notify queue. |
| 18 | ![alt text](evidence/image-43.png) | The tutor receives the "New assignment" email from SES. |
| 19 | ![alt text](evidence/image-44.png) | The notify Lambda log shows the email being sent. |
| 20 | ![alt text](evidence/image-45.png) | 6 subnets: public, app and data, in each of us-east-1a and us-east-1b. |
| 21 | ![alt text](evidence/image-46.png) | One NAT gateway per AZ for resilient outbound access. |
| 22 | ![alt text](evidence/image-47.png) | The database route table has only the `local` route, with no internet path. |
| 23 | ![alt text](evidence/image-48.png) | RDS: Multi-AZ = Yes, encrypted, not publicly accessible. |
| 24 | ![alt text](evidence/image-50.png) | The RDS primary and standby are in different AZs. |
| 25 | ![alt text](evidence/image-51.png) | Two Fargate API tasks are running, one in each AZ. |
| 26 | ![alt text](evidence/image-52.png) | Both ALB targets are healthy. |
| 27 | ![alt text](evidence/image-53.png) | The database security group allows 5432 only from the API and Lambda security groups. |
| 28 | ![alt text](evidence/image-54.png) | The DB password is managed by Secrets Manager and never appears in code. |
| 29 | ![alt text](evidence/image-55.png) | CloudWatch dashboard: ALB, ECS, RDS and queue metrics. |
| 30 | ![alt text](evidence/image-56.png) | CloudWatch alarms sent to SNS email. |

### 6.3 Cloud Architecture Lab (Task 3)

![alt text](<architecture/aws-architecture-diagram (11).png>)

## 7. Analysis and Discussion

**What was achieved.** The complete architecture was deployed from code, and both user walkthroughs work end to end on the live site:

- **Static frontend** through CloudFront and WAF
- **API on Fargate** across two AZs
- **RDS PostgreSQL Multi-AZ**
- **Autosave** to the database
- **Asynchronous auto-marking** (SQS → Lambda)
- **Direct-to-S3 uploads** with KMS encryption and 5-year lifecycle
- **Tutor email** through SES
- **CloudWatch monitoring**

A push to `main` redeploys everything without manual steps, which meets the "fully reproducible from code" requirement.

**Did the results match the expected outcome?** Yes for the functional and availability goals. Some production settings were reduced because of the shared, free-plan AWS account. They are documented as deliberate deviations:

| Production design | Deployed | Reason |
|---|---|---|
| RDS backups 7–35 days + PITR | 1 day (PITR still on) | Free-plan limit |
| Region near users | us-east-1 | VPC and Elastic IP quotas full in ap-south-1 |
| Cognito JWT checked by the API | `x-user-id` header stub (user pool and groups created) | Demo simplicity |
| HTTPS from CloudFront to the ALB with a custom domain | HTTP origin, locked to the CloudFront prefix list + secret header | No registered domain |
| ECS min 4 tasks with scheduled pre-scale | Min 2 (one per AZ), max 20 | Cost |

**Errors encountered and how they were resolved:**

| # | Error | Cause | Resolution |
|---|---|---|---|
| 1 | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Project name mismatch between the bootstrap role (`exam-platform`) and the workflow (`exam-tsd`); later, the trust policy `sub` did not match | Recreated the bootstrap as `exam-tsd`. **CloudTrail** showed that GitHub now sends `repo:owner@<id>/repo@<id>:ref:...` (immutable IDs), so the trust policy was changed to accept both formats |
| 2 | Variables arrived empty in the workflow | `TF_STATE_BUCKET` and the emails were saved as *Secrets*, but the workflow reads `vars.*` | Moved them to repository *Variables* |
| 3 | `VpcLimitExceeded`, `AddressLimitExceeded` | The shared account had reached 5 VPCs and 5 EIPs in ap-south-1 | Destroyed the partial stack and moved to us-east-1, which had free quota |
| 4 | S3 bucket stuck on "Still creating" for 30+ min | Bucket names deleted in one region cannot be reused immediately in another | Added the region to bucket names |
| 5 | `Error acquiring the state lock` | The cancelled run left a lock in S3 | `terraform force-unlock <id>` after confirming no run was active |
| 6 | `already exists` / `RouteAlreadyExists` | The cancelled run created resources before saving state | Imported the ALB and S3 endpoint with `terraform import`; removed a duplicate route table |
| 7 | `FreeTierRestrictionError` on RDS | Free plan limits backup retention | Set `backup_retention_period = 1` |
| 8 | Health check 503 "db unavailable" | `pg` with `PGSSLMODE=require` verifies the certificate, and Node does not trust the Amazon RDS CA | Added the RDS CA bundle to the image (`NODE_EXTRA_CA_CERTS`), so TLS is encrypted **and verified** |
| 9 | Marker Lambda could not connect | It read `PGUSER`/`PGPASSWORD` env vars that were never set | Read the credentials from Secrets Manager (as `init_db.py` does) |
| 10 | Browser upload failed | Newer AWS SDK versions add a checksum (for an empty body) to presigned URLs, and the URL also required an SSE header the browser didn't send | `requestChecksumCalculation: "WHEN_REQUIRED"`; rely on bucket default SSE-KMS |

**Observations:**

- **First deploy time.** RDS Multi-AZ (about 15–20 min) and CloudFront (about 5–10 min) dominate.
- **Never cancel a running `terraform apply`.** Cancelling left orphaned resources and a state lock, which took longer to clean up than waiting would have.
- **CloudTrail is the fastest way to debug IAM/OIDC denials.** It shows exactly what identity was presented.
- **Presigned uploads work well.** A 50 MB file never touches the API, so uploads cannot slow down exams.

## 8. Reflection

1. **What did I learn about these AWS services?** I learned how the services fit together into one highly available system, not just how each works alone:
   - **Multi-AZ** is a property of every tier (subnets, NAT, ALB, ECS, RDS), not one setting.
   - **SQS decouples slow work** from user requests.
   - **IAM roles with OIDC** remove the need for stored keys.
   - **KMS, TLS and Secrets Manager** together give encryption in transit and at rest.

2. **What challenges did I encounter?** Most of the difficulty was operational rather than design: OIDC trust policies, quotas in a shared account, free-plan limits, S3 naming rules, Terraform state locks and imports after a cancelled run, and TLS certificate verification to RDS. Each one had to be diagnosed from logs (GitHub Actions, CloudTrail, CloudWatch) rather than guessed.

3. **How would I apply this in a real cloud environment?** The same pattern suits any service with predictable spikes, such as university registration, results day or ticket sales. Before production I would:
   - enable Cognito JWT validation
   - add a custom domain with ACM certificates
   - use longer RDS backups with AWS Backup
   - add CloudTrail and interface VPC endpoints
   - add scheduled scale-out before exam windows
   - use separate dev/staging/prod environments with Terraform workspaces or modules

4. **What would I like to explore next?**
   - Load testing with 3,000 simulated users
   - Running the API on EKS for comparison with Fargate
   - Aurora Serverless v2 for the database
   - Cross-region disaster recovery
   - Blue/green deployments with CodeDeploy
   - Cost optimisation with Fargate Spot and Graviton

## 9. Conclusion

The objectives of this assignment were achieved. A production-grade architecture for an online exam platform was designed across two Availability Zones and documented service by service. It was implemented fully as Terraform code and deployed automatically by GitHub Actions on every push to `main`. Both required walkthroughs were shown working on the live system: opening an exam with 30-second autosave and auto-marking, and uploading an assignment directly to encrypted S3 storage with an email to the tutor. The design meets the availability, RPO/RTO, retention and encryption targets in its production form, and every deviation forced by the free-plan, shared account is documented.

The key concepts learned were:
- multi-tier, multi-AZ design
- decoupling with queues
- direct-to-S3 uploads with presigned URLs
- encryption with KMS and verified TLS
- secrets management
- keyless CI/CD with OIDC
- Infrastructure as Code with remote state

I also developed practical skills in debugging real cloud deployments with CloudTrail, CloudWatch Logs and Terraform state tools. These AWS services matter because they let one engineer deliver a secure, scalable, reproducible system that would otherwise need a large infrastructure team.

