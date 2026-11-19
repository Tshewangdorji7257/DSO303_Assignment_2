# Service Documentation

Online exam and assignment platform for 8,000 students and 400 staff. Targets: 99.9% availability during exams, survives loss of one AZ, RPO 5 minutes, RTO 1 hour, 5-year record retention, encryption in transit and at rest.

## Edge and network

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon Route 53 | DNS for the exam domain | Native alias records to CloudFront with health checks, no extra cost per query to AWS targets; cheaper and simpler than an external DNS provider that cannot alias to CloudFront | Public hosted zone, alias A/AAAA to CloudFront | CloudFront, ACM |
| AWS Certificate Manager (ACM) | TLS certificates | Free, auto-renewing certificates; avoids manually renewing third-party certificates | Certificate in us-east-1 for CloudFront, one in the app region for the ALB, DNS validation | CloudFront, ALB |
| Amazon CloudFront | CDN and single entry point | Serves static frontend from edge locations so 3,000 simultaneous students do not hit the origin; better than serving the frontend from the ALB or EC2, which would need extra capacity | Origin 1: S3 frontend bucket via Origin Access Control (default). Origin 2: ALB for `/api/*` with caching disabled. HTTPS only, TLS 1.2+, HTTP to HTTPS redirect | Route 53, WAF, S3, ALB |
| AWS WAF | Web firewall | Blocks common attacks and rate-limits abusive clients before they reach the app; Security Groups only filter by IP/port and cannot inspect HTTP requests | Attached to CloudFront. AWS Managed Common and SQL Injection rule sets, rate-based rule 2,000 requests per 5 min per IP | CloudFront |
| Amazon VPC | Isolated network | Private network with full control of subnets and routing; required to keep the database and compute off the public internet | 10.0.0.0/16, two AZs. Per AZ: public subnet, private app subnet, private DB subnet (no route to the internet) | All compute and data services |
| NAT Gateway | Outbound internet for private subnets | Managed and highly available inside an AZ; no patching, unlike a self-managed NAT instance | One per AZ so an AZ failure does not cut outbound access for the other AZ. Used for pulls and external calls | Private app subnets, Internet Gateway |
| VPC Gateway and Interface Endpoints | Private access to S3, ECR, SQS, Secrets Manager, CloudWatch Logs | Keeps traffic on the AWS network and reduces NAT cost and exposure; better than routing through NAT | Gateway endpoint for S3; interface endpoints for ECR (api, dkr), SQS, Secrets Manager, Logs | ECS tasks, Lambda |
| Security Groups | Instance-level firewall | Stateful and attachable to resources, simpler to audit than NACL-only rules | ALB: 443 from CloudFront prefix list. ECS: 8080 from ALB SG only. RDS: 5432 from ECS SG and Lambda SG only | ALB, ECS, RDS, Lambda |

## Frontend, API and compute

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon S3 (frontend bucket) | Hosts the static web app | Cheapest and most durable way to host static files; no servers to scale, unlike running the frontend on EC2 | Private bucket, Origin Access Control only, SSE-S3, versioning on | CloudFront |
| Application Load Balancer | Spreads API traffic across AZs | Layer 7 routing and health checks, integrates with ECS and WAF; a Network Load Balancer lacks HTTP-level features | Internet-facing in public subnets in both AZs, HTTPS listener, health check `/api/health`, deregistration delay 30 s | CloudFront, ECS |
| Amazon ECS on AWS Fargate | Runs the API containers | No servers to patch and fast scaling per task; simpler than EC2 Auto Scaling or Kubernetes (EKS) for one small service | Tasks in private app subnets across both AZs, 0.5 vCPU / 1 GB, min 4 tasks (2 per AZ), max 40. Target tracking on CPU 60% and request count, scheduled pre-scale before exams | ALB, RDS, SQS, S3, Secrets Manager |
| Amazon ECR | Container image registry | Private, integrated with ECS and IAM, with scanning; avoids running a separate registry | Scan on push, immutable tags, lifecycle rule keeps last 10 images, encrypted with KMS | ECS, GitHub Actions |
| Application Auto Scaling | Scales ECS tasks | Reacts to load and supports scheduled actions; fixed capacity would be too small at peak or wasteful all year | Target tracking plus scheduled scale-out 30 minutes before each exam window | ECS, CloudWatch |

## Authentication

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon Cognito | Sign-in and role-based access | Managed user pools with groups and JWTs; cheaper and safer than building and storing passwords ourselves, and scales to thousands of logins without servers | User pool with groups `student`, `tutor`, `admin`, MFA required for tutors and admins, password policy, JWT validated by the API, can federate with the university SSO | CloudFront/ALB, ECS API |

## Data

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon RDS for PostgreSQL (Multi-AZ) | Stores users' exam data, answers and results | Managed relational database with synchronous standby in a second AZ and automatic failover; exam data is relational and needs transactions, so better than DynamoDB for marking queries, and better than self-managed PostgreSQL on EC2 | db.t3.medium (scale up for peak), 50 GB gp3, Multi-AZ, private DB subnets, not publicly accessible, KMS encryption, TLS enforced, automated backups 7 days with point-in-time recovery (restore to within 5 minutes), deletion protection | ECS, Lambda, Secrets Manager |
| Amazon S3 (uploads bucket) | Stores assignment files (PDF/ZIP up to 50 MB) | Cheaper and more durable (11 nines) than EBS or EFS; presigned URLs keep 50 MB uploads off the API | Private, Block Public Access, SSE-KMS, versioning, bucket policy requires TLS. Lifecycle: Standard to Glacier Flexible Retrieval after 90 days, expire after 1,830 days (5 years). Event notification to SNS on upload. Cross-region replication optional | ECS (presigned URL), SNS, Lambda |
| AWS KMS | Encryption keys | Central key control and audit; AWS-owned default keys give no control or key-use logs | Customer-managed keys for RDS, S3, SQS and Secrets Manager, annual rotation | RDS, S3, SQS, Secrets Manager |
| AWS Secrets Manager | Stores DB credentials | Automatic rotation and IAM-controlled access; safer than environment variables or config files in code | RDS-managed secret, 30-day rotation, injected into ECS tasks and Lambda at start | ECS, Lambda, RDS |

## Asynchronous processing and notifications

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon SQS (marking queue + DLQ) | Buffers marking jobs after exam submission | Decouples submission from marking so the 5-minute peak does not overload the database; simpler and cheaper than Kafka or running RabbitMQ | Standard queue, visibility timeout 6x Lambda timeout, DLQ after 3 receives, SSE-KMS, retention 4 days | ECS API (producer), Lambda (consumer) |
| AWS Lambda (marker) | Auto-marks MCQs | Runs only when a message arrives and scales with the queue; cheaper than an always-on worker | Python 3.12, VPC private subnets, 512 MB, 60 s timeout, SQS event source batch size 10, reserved concurrency 20 to protect the DB, dead-letter queue on failure | SQS, RDS, SES |
| Amazon SNS | Notifies tutors of uploads and fans out alarms | Simple publish/subscribe to email without writing code | Topic `assignment-uploads` fed by S3 events, tutor email subscriptions; topic `ops-alerts` for alarms | S3, CloudWatch, SES/email |
| Amazon SES | Sends result-release emails | Low cost per email and high deliverability; better than running our own mail server | Verified domain with DKIM and SPF, out of sandbox for production, bounce and complaint handling to SNS | Lambda, SNS |

## Monitoring, security and delivery

| Service | Role | Why over an alternative | Configuration | Connects to |
|---|---|---|---|---|
| Amazon CloudWatch | Logs, metrics, alarms, dashboard | Native to all services, no agents to run; cheaper to start than third-party tools | Alarms: ALB 5xx, unhealthy hosts, ECS CPU, RDS CPU/connections/free storage, SQS queue age and DLQ depth. Dashboard for exam week. Log retention 90 days | All services, SNS |
| AWS CloudTrail | Audit log of API activity | Required evidence of who changed what; needed for records and compliance | Multi-region trail to a dedicated S3 bucket, log file validation | S3, KMS |
| AWS IAM | Access control | Least-privilege roles per service; avoids long-lived access keys | Separate task roles for API and Lambda; GitHub OIDC role for deployment, no stored keys | All services |
| AWS Backup | Central backups and retention | One policy across RDS and S3 for the 5-year retention rule; manual snapshots are easy to forget | Daily backup plan, 35-day vault retention for RDS, yearly copy kept 5 years | RDS, S3, KMS |
| GitHub Actions | CI/CD pipeline | Already hosts the repository and uses OIDC to AWS; no separate CI server to run, unlike Jenkins | On push to `main`: build image, push to ECR, `terraform validate` and `apply`, deploy frontend to S3 and invalidate CloudFront | ECR, ECS, S3, Terraform |
| Terraform (with S3 + DynamoDB state) | Infrastructure as code | Reproducible, reviewable and works with the pipeline; console-built infrastructure cannot be recreated reliably | Remote state in S3 with versioning, DynamoDB state lock, modules for network, data, compute | All services |

## Meeting the targets

| Target | How it is met |
|---|---|
| 99.9% availability | ALB, ECS and RDS span two AZs; CloudFront and S3 are regional/global managed services; health checks and auto-replacement of tasks |
| Survive one AZ loss | Tasks run in both AZs, NAT per AZ, RDS Multi-AZ with automatic failover (about 60 to 120 seconds) |
| RPO 5 minutes | Multi-AZ replicates synchronously; PITR restores to within 5 minutes; autosave every 30 s writes answers to the database |
| RTO 1 hour | Failover is automatic; full rebuild from Terraform plus PITR restore is within one hour |
| 5-year retention | S3 lifecycle (Glacier after 90 days, expire at 5 years), AWS Backup yearly copy, versioning |
| Encryption in transit | TLS 1.2+ at CloudFront and ALB, TLS to RDS, HTTPS-only S3 bucket policy |
| Encryption at rest | KMS on RDS, S3, SQS, Secrets Manager and ECR |
