variable "aws_region" {
  description = "AWS region to create the state bucket and lock table in"
  type        = string
  default     = "eu-west-1"
}

variable "project_name" {
  description = "Project name prefix — used in bucket and table names"
  type        = string
  default     = "smartapps"
}
