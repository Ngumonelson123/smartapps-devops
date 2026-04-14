# terraform/bootstrap/main.tf
# Creates the S3 bucket and DynamoDB table that all other Terraform workspaces use for remote state storage and locking.
# The chicken-and-egg problem: Terraform needs a backend to store state,but the backend infrastructure must itself be created first.
# Solution: bootstrap runs with a LOCAL backend (state stored on disk),provisions the S3 + DynamoDB resources, then all other modules use the S3 remote backend.

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "SmartApps"
      ManagedBy = "Terraform-Bootstrap"
      Purpose   = "remote-state-infrastructure"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  # Bucket name includes account ID — globally unique, no collision risk
  bucket_name   = "${var.project_name}-terraform-state-${local.account_id}"
  dynamodb_name = "${var.project_name}-tf-locks"
}
# S3 BUCKET — Remote State Storage
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # Prevent accidental deletion of the state bucket
  lifecycle {
    prevent_destroy = true
  }
}

# Enable versioning — lets you recover from accidental state corruption
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Server-side encryption — state files may contain sensitive ARNs / IPs
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block ALL public access — state files must never be public
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Object ownership — disable ACLs, use bucket policies only
resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Lifecycle policy — move old state versions to cheaper storage after 90 days
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}
# DYNAMODB TABLE — State Locking

# Prevents two engineers (or two CI runs) from modifying the same state at the same time. Terraform acquires a lock before reading/writing state and releases it when done. If a run crashes, the lock auto-expires.
resource "aws_dynamodb_table" "locks" {
  name         = local.dynamodb_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  # Point-in-time recovery — can restore table to any second in last 35 days
  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# OUTPUTS
output "backend_bucket" {
  description = "S3 bucket name for Terraform remote state"
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "DynamoDB table name for state locking"
  value       = aws_dynamodb_table.locks.name
}

output "aws_region" {
  description = "AWS region"
  value       = local.region
}

output "backend_hcl_snippet" {
  description = "Copy this into terraform/backend.hcl"
  value       = <<-EOT
    bucket         = "${aws_s3_bucket.state.bucket}"
    region         = "${local.region}"
    dynamodb_table = "${aws_dynamodb_table.locks.name}"
    encrypt        = true
  EOT
}
