# terraform/main.tf — SmartApps AWS Infrastructure
# Author  : Nelson Ngumo
# Manages : VPC, EKS, ECR, Secrets Manager, IAM

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws        = { source = "hashicorp/aws",        version = "~> 5.0"  }
    kubernetes = { source = "hashicorp/kubernetes",  version = "~> 2.23" }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project    = "SmartApps"
      ManagedBy  = "Terraform"
      CostCenter = "Engineering"
    }
  }
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_caller_identity" "current" {}

locals {
  cluster_name = "${var.project_name}-eks-${var.environment}"
  account_id   = data.aws_caller_identity.current.account_id
}

# VPC
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.2"

  name = "${var.project_name}-vpc-${var.environment}"
  cidr = var.vpc_cidr
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = var.environment == "qa"   # Cost saving in QA
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

# EKS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_version
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets
  enable_irsa     = true

  cluster_endpoint_public_access = true

  # Grant cluster-admin to the IAM identity running Terraform (your root/admin user)
  enable_cluster_creator_admin_permissions = true

  # Grant additional IAM principals console + kubectl access
  access_entries = {
    admin = {
      principal_arn = "arn:aws:iam::${local.account_id}:root"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  eks_managed_node_groups = {
    app_nodes = {
      instance_types = var.environment == "prod" ? ["t3.medium"] : ["t3.small"]
      min_size       = var.environment == "prod" ? 2 : 1
      max_size       = var.environment == "prod" ? 6 : 3
      desired_size   = var.environment == "prod" ? 3 : 1
      capacity_type  = var.environment == "prod" ? "ON_DEMAND" : "SPOT"
    }
  }
}

# ECR
resource "aws_ecr_repository" "app" {
  name                 = "${var.service_name}-${var.environment}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration    { encryption_type = "AES256" }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [
      { rulePriority = 1, description = "Remove untagged after 1 day",
        selection = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 1 },
        action = { type = "expire" } },
      { rulePriority = 2, description = "Keep last 10 tagged images",
        selection = { tagStatus = "tagged", tagPrefixList = [var.environment], countType = "imageCountMoreThan", countNumber = 10 },
        action = { type = "expire" } }
    ]
  })
}

# Secrets Manager
resource "aws_kms_key" "secrets" {
  description             = "CMK for Secrets Manager — ${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "app_config" {
  name                    = "/${var.project_name}/${var.environment}/app-config"
  description             = "App config for ${var.environment}"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = var.environment == "prod" ? 30 : 7
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode({
    APP_ENV  = var.environment
    DB_HOST  = "SET_VIA_CONSOLE_OR_PIPELINE"
    API_KEY  = "SET_VIA_CONSOLE_OR_PIPELINE"
  })
  lifecycle { ignore_changes = [secret_string] }
}

# IAMenkins Deploy Role
resource "aws_iam_role" "jenkins" {
  name = "${var.project_name}-jenkins-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "jenkins" {
  role = aws_iam_role.jenkins.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ecr:*"],                        Resource = aws_ecr_repository.app.arn },
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"],    Resource = "*" },
      { Effect = "Allow", Action = ["eks:DescribeCluster"],          Resource = module.eks.cluster_arn },
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.app_config.arn },
      { Effect = "Allow", Action = ["sts:GetCallerIdentity"],        Resource = "*" }
    ]
  })
}
