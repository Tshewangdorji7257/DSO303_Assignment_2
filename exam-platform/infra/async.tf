# ---------- Queues ----------
resource "aws_sqs_queue" "marking_dlq" {
  name                      = "${var.project}-marking-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "marking" {
  name                       = "${var.project}-marking"
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.marking_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "notify_dlq" {
  name                      = "${var.project}-notify-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "notify" {
  name                       = "${var.project}-notify"
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notify_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "notify" {
  queue_url = aws_sqs_queue.notify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.notify.arn
      Condition = {
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.uploads.arn }
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

# ---------- SES (sandbox: the address must be verified by clicking the emailed link) ----------
resource "aws_ses_email_identity" "notify" {
  email = var.notify_email
}

# ---------- Lambda packages ----------
# Run scripts/build-lambda.sh first: it creates app/marker/pkg (code + psycopg2 + SQL files)
data "archive_file" "marker" {
  type        = "zip"
  source_dir  = "${path.root}/../app/marker/pkg"
  output_path = "${path.root}/build/marker.zip"
}

data "archive_file" "notify" {
  type        = "zip"
  source_dir  = "${path.root}/../app/notify"
  output_path = "${path.root}/build/notify.zip"
}

# ---------- IAM for Lambdas ----------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "marker" {
  name               = "${var.project}-marker"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "marker_vpc" {
  role       = aws_iam_role.marker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "marker" {
  role = aws_iam_role.marker.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_db_instance.main.master_user_secret[0].secret_arn },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.marking.arn }
    ]
  })
}

resource "aws_iam_role" "notify" {
  name               = "${var.project}-notify"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "notify_logs" {
  role       = aws_iam_role.notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "notify" {
  role = aws_iam_role.notify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ses:SendEmail"], Resource = "*" },
      { Effect = "Allow", Action = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], Resource = aws_sqs_queue.notify.arn }
    ]
  })
}

# ---------- Lambda functions ----------
resource "aws_cloudwatch_log_group" "marker" {
  name              = "/aws/lambda/${var.project}-marker"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.project}-notify"
  retention_in_days = 30
}

resource "aws_lambda_function" "marker" {
  function_name    = "${var.project}-marker"
  role             = aws_iam_role.marker.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.marker.output_path
  source_code_hash = data.archive_file.marker.output_base64sha256
  vpc_config {
    subnet_ids         = aws_subnet.app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      PGHOST        = aws_db_instance.main.address
      PGDATABASE    = "exam"
      PGSSLMODE     = "require"
      PG_SECRET_ARN = aws_db_instance.main.master_user_secret[0].secret_arn
    }
  }
  depends_on = [aws_cloudwatch_log_group.marker, aws_iam_role_policy_attachment.marker_vpc]
}

resource "aws_lambda_function" "db_init" {
  function_name    = "${var.project}-db-init"
  role             = aws_iam_role.marker.arn
  runtime          = "python3.12"
  handler          = "init_db.handler"
  timeout          = 120
  filename         = data.archive_file.marker.output_path
  source_code_hash = data.archive_file.marker.output_base64sha256
  vpc_config {
    subnet_ids         = aws_subnet.app[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      PGHOST        = aws_db_instance.main.address
      PGDATABASE    = "exam"
      PG_SECRET_ARN = aws_db_instance.main.master_user_secret[0].secret_arn
    }
  }
  depends_on = [aws_iam_role_policy_attachment.marker_vpc]
}

# Loads schema + seed into the private database on every deploy (idempotent)
resource "aws_lambda_invocation" "db_init" {
  function_name = aws_lambda_function.db_init.function_name
  input         = jsonencode({ run = "init" })
  triggers      = { code = data.archive_file.marker.output_base64sha256 }
  depends_on    = [aws_db_instance.main]
}

resource "aws_lambda_function" "notify" {
  function_name    = "${var.project}-notify"
  role             = aws_iam_role.notify.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  timeout          = 30
  filename         = data.archive_file.notify.output_path
  source_code_hash = data.archive_file.notify.output_base64sha256
  environment {
    variables = {
      SENDER      = var.notify_email
      TUTOR_EMAIL = var.notify_email
    }
  }
  depends_on = [aws_cloudwatch_log_group.notify, aws_iam_role_policy_attachment.notify_logs]
}

resource "aws_lambda_event_source_mapping" "marking" {
  event_source_arn = aws_sqs_queue.marking.arn
  function_name    = aws_lambda_function.marker.arn
  batch_size       = 10
}

resource "aws_lambda_event_source_mapping" "notify" {
  event_source_arn = aws_sqs_queue.notify.arn
  function_name    = aws_lambda_function.notify.arn
  batch_size       = 10
}
