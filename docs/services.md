# Service Documentation

Online exam and assignment platform for 8,000 students and 400 staff. Targets: 99.9% availability during exams, survive the loss of one AZ, RPO 5 minutes, RTO 1 hour, 5-year record retention, encryption in transit and at rest.

The tables describe the **production design**. The final section lists where the deployed demo differs and why (a shared AWS account on the free plan).

## Edge and network

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon Route 53 | DNS for the exam domain | Native alias records to CloudFront at no per-query cost for AWS targets, plus health checks; an external DNS provider cannot alias to CloudFront | Public hosted zone, alias A/AAAA records to CloudFront | CloudFront, ACM |
| AWS Certificate Manager (ACM) | TLS certificates | Free, auto-renewing certificates; no manual renewal of third-party certificates | Certificate in us-east-1 for CloudFront and one in the app region for the ALB, DNS validation | CloudFront, ALB |
| Amazon CloudFront | CDN and single entry point | Serves the static frontend from edge locations, so 3,000 students starting at once do not hit the origin; serving the frontend from the ALB or EC2 would need extra capacity | Origin 1: S3 frontend bucket via Origin Access Control (default behaviour, CachingOptimized). Origin 2: ALB for `/api/*` (CachingDisabled, all viewer headers forwarded) with a secret `X-Origin-Verify` header. HTTPS only, TLS 1.2+, HTTP→HTTPS redirect, HTTP/2 and HTTP/3, PriceClass_100 | Route 53, WAF, S3, ALB |
| AWS WAF | Web application firewall | Blocks common attacks and rate-limits abusive clients before they reach the app; security groups filter only by IP and port and cannot inspect HTTP requests | Web ACL attached to CloudFront (global, us-east-1). Rate-based rule: 2,000 requests per 5 min per IP. AWS Managed Rules: Common Rule Set and Known Bad Inputs. CloudWatch metrics and sampled requests on | CloudFront |
| Amazon VPC | Isolated network | Private network with full control of subnets and routing; needed to keep compute and the database off the public internet | 10.0.0.0/16 across two AZs. Per AZ: public subnet (ALB, NAT), private app subnet (Fargate, Lambda), private DB subnet (RDS, no route to the internet) | All compute and data services |
| Internet Gateway | Internet access for public subnets | Required for the internet-facing ALB and the NAT gateways; managed and redundant, with no capacity to size | One per VPC, default route in the public route table | Public subnets, NAT Gateway, ALB |
| NAT Gateway | Outbound internet for private app subnets | Managed and highly available within an AZ; no patching or scaling, unlike a self-managed NAT instance | One per AZ, each with its own Elastic IP and app route table, so losing an AZ does not cut outbound access for the other AZ. Used for image pulls and AWS API calls (SES, SQS, Secrets Manager) | Private app subnets, Internet Gateway |
| VPC Gateway and Interface Endpoints | Private access to AWS services | Keep traffic on the AWS network and cut NAT data charges and exposure; better than sending all AWS API traffic through NAT | Gateway endpoint for S3 on both app route tables. Interface endpoints for ECR (api, dkr), SQS, Secrets Manager and CloudWatch Logs | ECS tasks, Lambda |
| Security Groups | Stateful firewall per resource | Attached to resources and reference each other by ID, so they are simpler to audit than NACL-only rules | ALB: 443 from the CloudFront origin-facing managed prefix list only. ECS: 8080 from the ALB SG only. RDS: 5432 from the ECS SG and Lambda SG only. Lambda: no inbound | ALB, ECS, RDS, Lambda |

## Frontend, API and compute

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon S3 (frontend bucket) | Hosts the static web app | The cheapest and most durable way to host static files; no servers to scale, unlike running the frontend on EC2 | Private bucket, Block Public Access, readable only by the CloudFront distribution (OAC bucket policy), SSE-S3. Deployed by `aws s3 sync` plus a CloudFront invalidation in the pipeline | CloudFront |
| Application Load Balancer | Spreads API traffic across AZs | Layer 7 routing, health checks and header-based rules, and it integrates with ECS; a Network Load Balancer lacks HTTP-level features | Internet-facing in both public subnets. HTTPS listener whose rule forwards only requests carrying the secret CloudFront header (all others get 403). Target group: IP targets on port 8080, health check `/api/health` (every 15 s, 2 healthy / 3 unhealthy), deregistration delay 30 s | CloudFront, ECS |
| Amazon ECS on AWS Fargate | Runs the API containers | No servers to patch and fast per-task scaling; simpler than EC2 Auto Scaling groups or Kubernetes (EKS) for one small stateless service | Tasks in both private app subnets, 0.5 vCPU / 1 GB, x86_64. Min 4 tasks (2 per AZ) in exam weeks, max 40. Deployment circuit breaker with automatic rollback. Container Insights on. DB credentials injected from Secrets Manager | ALB, RDS, SQS, S3, Secrets Manager |
| Amazon ECR | Container image registry | Private, integrated with ECS and IAM, with vulnerability scanning; no separate registry to run | Scan on push, immutable tags (commit SHA), lifecycle rule keeps the last 10 images, KMS encryption | ECS, GitHub Actions |
| Application Auto Scaling | Scales ECS tasks | Reacts to load and supports scheduled actions; fixed capacity would be too small at peak or wasteful the rest of the year | Target tracking on average CPU 50% and on ALB requests per target (300), scale-out cooldown 30 s, scale-in 300 s. Scheduled action raises the minimum 30 minutes before each exam window | ECS, CloudWatch |

## Authentication

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon Cognito | Sign-in and role-based access | Managed user pools with groups and JWTs; cheaper and safer than building and storing passwords ourselves, and scales to thousands of logins without servers | User pool with email sign-in, password policy (12+ chars, upper, lower, number, symbol), groups `students`, `tutors`, `admins`, MFA required for tutors and admins. Public SPA client (SRP auth, refresh tokens). The API validates the JWT and group. Can federate with the university SSO | Frontend, ECS API |

## Data

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon RDS for PostgreSQL (Multi-AZ) | Stores exams, questions, autosaved answers, submissions and results | Managed relational database with a synchronous standby in a second AZ and automatic failover. Exam data is relational and needs transactions and upserts, so it suits PostgreSQL better than DynamoDB, and it is far less work than self-managed PostgreSQL on EC2 | PostgreSQL 16, db.t3.medium (scale up for exam weeks), gp3 storage with autoscaling, Multi-AZ, private DB subnets, not publicly accessible, KMS encryption, TLS required (clients verify the Amazon RDS CA), automated backups 7 days with point-in-time recovery, deletion protection. Master password managed by Secrets Manager | ECS, Lambda, Secrets Manager |
| Amazon S3 (uploads bucket) | Stores assignment files (PDF/ZIP up to 50 MB) | Cheaper and more durable (11 nines) than EBS or EFS; presigned URLs let the browser upload 50 MB files directly, keeping them off the API | Private, Block Public Access, default SSE-KMS with an S3 Bucket Key, versioning, bucket policy denies non-TLS requests, CORS allows `PUT` only from the site origin. Lifecycle: Standard-IA after 30 days, Glacier after 180 days, expire after 1,826 days (5 years), old versions after 365 days, abort incomplete multipart uploads after 7 days. `ObjectCreated` events on `submissions/` go to the SQS notify queue | API (presigned URL), SQS, KMS |
| AWS KMS | Encryption keys | Central key control and an audit trail of key use; AWS-owned default keys give neither | Customer-managed key with automatic annual rotation, used for RDS, the uploads bucket, SQS and Secrets Manager | RDS, S3, SQS, Secrets Manager |
| AWS Secrets Manager | Stores DB credentials | Automatic rotation and IAM-controlled access; safer than passwords in environment files or code | RDS-managed master secret (rotated automatically by RDS, every 7 days by default). Injected into ECS tasks as secrets; Lambdas read it at runtime. Read access only for the ECS execution role and the Lambda role | ECS, Lambda, RDS |

## Asynchronous processing and notifications

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon SQS: marking queue + DLQ | Buffers marking jobs after exam submission | Decouples submission from marking, so a burst of 3,000 submissions does not overload the database; simpler and cheaper than running Kafka or RabbitMQ | Standard queue, visibility timeout 6× the Lambda timeout, DLQ after 5 receives (14-day retention), SSE-KMS. CloudWatch alarm on DLQ depth | ECS API (producer), marker Lambda |
| Amazon SQS: notify queue + DLQ | Buffers upload events for tutor email | Lets S3 events be retried and survive Lambda or SES errors; a failed email is never silently lost | Standard queue fed by S3 `ObjectCreated` events (queue policy allows only the uploads bucket from this account), DLQ after 5 receives, SSE. CloudWatch alarm on DLQ depth | S3, notify Lambda |
| AWS Lambda: marker | Auto-marks MCQs | Runs only when messages arrive and scales with the queue; cheaper than an always-on worker | Python 3.12, private app subnets, 512 MB, 60 s timeout, SQS event source with batch size 10, reserved concurrency 20 to protect the database, reads DB credentials from Secrets Manager | SQS, RDS, Secrets Manager |
| AWS Lambda: notify | Emails the tutor when an assignment arrives (and on result release) | Event-driven with no server; a few lines of code instead of a mail worker | Python 3.12, SQS event source with batch size 10, parses the S3 event (student, file, size) and calls SES `SendEmail` | SQS, SES |
| AWS Lambda: db-init | Loads the schema and seed data into the private database | RDS has no public endpoint, so a Lambda inside the VPC applies the SQL during each deploy; no bastion host or manual step | Python 3.12, private subnets, invoked by Terraform on each deploy (idempotent `CREATE IF NOT EXISTS` / `ON CONFLICT`) | RDS, Secrets Manager |
| Amazon SNS | Delivers operational alarms | Simple publish/subscribe to email or chat without writing code | Topic `ops-alerts` with email subscriptions for the operations team, fed by CloudWatch alarms | CloudWatch, email |
| Amazon SES | Sends upload notifications and result-release emails | Low cost per email and high deliverability; better than running our own mail server | Verified domain with DKIM and SPF, moved out of the sandbox for production, bounce and complaint handling to SNS | Notify Lambda |

## Monitoring, security and delivery

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon CloudWatch | Logs, metrics, alarms, dashboard | Native to every service with no agents to run; cheaper to start with than third-party tools | Alarms: ALB 5xx, unhealthy targets, RDS CPU, DLQ depth for both queues (plus ECS CPU, RDS connections and free storage, and SQS oldest-message age in production). Dashboard `exam-tsd` for exam week. Log retention 90 days | All services, SNS |
| AWS CloudTrail | Audit log of API activity | Records who changed what, for compliance; also used to debug the OIDC role trust | Multi-region trail to a dedicated S3 bucket, log file validation, KMS encryption | S3, KMS |
| AWS IAM | Access control | Least-privilege roles per service; no long-lived access keys | Separate roles: ECS execution role (pull image, read the DB secret), ECS task role (`s3:PutObject` on `submissions/*`, `sqs:SendMessage`, KMS), marker and notify Lambda roles, and the GitHub OIDC deploy role (trusted only for this repository) | All services |
| AWS Backup | Central backups and long-term retention | One policy across RDS and S3 for the 5-year retention rule; manual snapshots are easy to forget | Daily backup plan, 35-day vault retention for RDS, yearly copy kept for 5 years | RDS, S3, KMS |
| GitHub Actions | CI/CD pipeline | Already hosts the repository and uses OIDC to AWS; no separate CI server to run, unlike Jenkins | On push to `main`: assume the role via OIDC, build the Lambda package, `terraform init/validate`, build and push the image to ECR (SHA tag), `terraform apply`, sync the frontend to S3, invalidate CloudFront, smoke-test `/api/health` | ECR, ECS, S3, CloudFront, Terraform |
| Terraform (S3 remote state) | Infrastructure as code | Reproducible, reviewable and run by the pipeline; console-built infrastructure cannot be recreated reliably | Remote state in a versioned, encrypted S3 bucket with native S3 state locking (`use_lockfile`). Separate bootstrap stack for the state bucket and OIDC role. Code split by layer: network, edge, compute, data, async, monitoring | All services |

## Meeting the targets

| Target | How it is met |
|---|---|
| 99.9% availability | ALB, ECS tasks, NAT and RDS span two AZs; CloudFront, S3, SQS and Lambda are managed regional or global services; ALB health checks and the ECS circuit breaker replace bad tasks automatically |
| Survive one AZ loss | Tasks run in both AZs, one NAT per AZ, RDS Multi-AZ with automatic failover (about 60–120 s) and the same endpoint name |
| RPO 5 minutes | Autosave every 30 s writes answers to RDS; Multi-AZ replicates synchronously; PITR restores to within 5 minutes |
| RTO 1 hour | Failover is automatic; a full rebuild from Terraform plus a PITR restore fits within one hour |
| 5-year retention | S3 lifecycle (Standard-IA at 30 days, Glacier at 180 days, expire at 1,826 days), versioning, AWS Backup yearly copy |
| Encryption in transit | TLS 1.2+ at CloudFront and the ALB, verified TLS from the API to RDS, HTTPS-only bucket policy on uploads |
| Encryption at rest | KMS on RDS, the uploads bucket, SQS, Secrets Manager and ECR; SSE-S3 on the frontend bucket |

## Deployed demo vs production design

The demo was deployed by the pipeline into a **shared AWS account on the free plan**. These settings were reduced on purpose; everything else matches the tables above.

| Item | Production design | Deployed demo | Reason |
|---|---|---|---|
| Region | Region near users | us-east-1 | ap-south-1 had reached the VPC (5) and Elastic IP (5) quotas in the shared account |
| Route 53 + ACM custom domain | Yes | CloudFront default `*.cloudfront.net` certificate | No registered domain |
| CloudFront → ALB | HTTPS (ACM), ALB SG 443 | HTTP on 80, locked to the CloudFront prefix list and a secret origin header | No custom domain for an ALB certificate |
| Cognito sign-in | JWT validated by the API | User pool and groups created; API uses an `x-user-id` stub | Demo simplicity |
| RDS | db.t3.medium, 7-day backups, deletion protection | db.t4g.micro, 20 GB (autoscaling to 100), 1-day backups (PITR on), no deletion protection | Free-plan limits and easy tear-down |
| ECS capacity | Min 4, max 40, scheduled pre-scale | Min 2 (one per AZ), max 20, no scheduled action | Cost |
| ECR | Immutable tags, KMS | Mutable tags (SHA-tagged images), AES-256 | Pipeline re-runs |
| SQS | SSE-KMS, visibility 6× Lambda timeout | SQS-managed SSE, visibility 60 s | Simplicity |
| Marker Lambda | 512 MB, 60 s, reserved concurrency 20 | 256 MB, 30 s, no reserved concurrency | Account concurrency limits |
| SES | Verified domain, production access | One verified email address (sandbox) | No domain |
| CloudTrail, AWS Backup, interface endpoints | Yes | Not deployed | Cost |
| Log retention | 90 days | 30 days | Cost |