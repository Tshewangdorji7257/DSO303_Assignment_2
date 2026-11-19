variable "region" {
  type    = string
  default = "us-east-1"
}
variable "project" {
  type    = string
  default = "exam-platform"
}
variable "image_tag" {
  type    = string
  default = "latest"
}
variable "alert_email" {
  type        = string
  description = "Receives CloudWatch alarm emails"
}
variable "notify_email" {
  type        = string
  description = "SES sender and tutor recipient (must be verified in SES)"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
variable "api_min_tasks" {
  type    = number
  default = 2 # one per AZ
}
variable "api_max_tasks" {
  type    = number
  default = 20
}
