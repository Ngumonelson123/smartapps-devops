# SmartApps — Production DevOps Pipeline

**Microservice deployment pipeline** with Docker, GitHub Actions, Amazon EKS, Amazon ECR, and Terraform.  
Covers the full lifecycle: local development → QA → Production, with semantic versioning, automated rollback, and zero-hardcoded credentials.

> **Case Study:** Smart Applications International — DevOps Engineer Technical Assessment  
> **Author:** Nelson Ngumo

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Technology Stack & Rationale](#technology-stack--rationale)
3. [Project Structure](#project-structure)
4. [Prerequisites](#prerequisites)
5. [Quick Start — Run Locally](#quick-start--run-locally)
6. [Step-by-Step: Build, Tag, Push (deploy.sh)](#step-by-step-build-tag-push)
7. [Environment Separation & Secrets](#environment-separation--secrets)
8. [Rollback Workflow](#rollback-workflow)
9. [GitHub Actions CI/CD](#github-actions-cicd)
10. [Terraform — Bootstrap Remote State](#terraform--bootstrap-remote-state)
11. [Terraform — AWS Infrastructure](#terraform--aws-infrastructure)
12. [Kubernetes Manifests](#kubernetes-manifests)
13. [Health Checks & Validation](#health-checks--validation)
14. [QA → Production Promotion Checklist](#qa--production-promotion-checklist)
15. [Security Best Practices Applied](#security-best-practices-applied)
16. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Developer
   │
   │  git push / git tag v1.2.0
   ▼
GitHub Repository
   │
   ├── CI Workflow (ci.yml) ──── triggered on every push to main
   │     │  1. npm test (unit tests must pass)
   │     │  2. docker build  (multi-stage, tests run inside builder)
   │     │  3. docker push → ECR QA  (tagged 1.2.0-qa)
   │     │  4. Health check validation (curl /health on running container)
   │     └── QA image live in ECR
   │
   └── CD Workflow (cd.yml) ─── triggered manually or on Release
         │  1. QA Gate: verify 1.2.0-qa exists in ECR
         │  2. ECR Scan Gate: 0 CRITICAL CVEs required
         │  3. Human Approval (GitHub Environment protection)
         │  4. docker build + push → ECR Prod (tagged 1.2.0-prod)
         │  5. kubectl set image → EKS rolling update
         │  6. Rollout status watch → auto-rollback on failure
         └── Production deployment complete
```

See [`docs/diagrams/architecture.svg`](docs/diagrams/architecture.svg) for the full interactive diagram.

---

## Technology Stack & Rationale

| Component | Choice | Why |
|-----------|--------|-----|
| **CI/CD** | GitHub Actions | Native to the repo, OIDC auth to AWS (no static keys), free for public repos, matrix builds, built-in approval gates via Environments |
| **Container Registry** | Amazon ECR | IAM-native auth, scan-on-push vulnerability detection, lifecycle policies, private per-environment repos |
| **Orchestration** | Amazon EKS | Managed Kubernetes control plane, IRSA for pod-level IAM, native rolling updates + HPA |
| **IaC** | Terraform | Multi-cloud portability, plan/apply workflow, remote state with locking, team-friendly |
| **Secrets** | AWS Secrets Manager | Rotation support, IAM-scoped access, audit logging via CloudTrail, zero plaintext |
| **Auth** | OIDC (GitHub → AWS) | Short-lived tokens, no static access keys anywhere in the pipeline |
| **Local Registry** | Docker registry:2 | Lets you run the entire pipeline on your laptop without cloud access |

**Why GitHub Actions over Jenkins?**  
Jenkins requires infrastructure to run and maintain (the agent servers). GitHub Actions is serverless — it runs on GitHub-managed compute, scales to zero, and integrates natively with your Git workflow. The OIDC integration with AWS means you never store AWS credentials as secrets at all.

---

## Project Structure

```
smartapps-devops/
│
├── app/                          # Application source code
│   ├── src/
│   │   └── server.js             # Express.js microservice (/health, /ready, /)
│   ├── server.test.js            # Jest unit tests (run inside Docker build)
│   └── package.json
│
├── docker/                       # Container configuration
│   ├── Dockerfile                # Multi-stage build (builder → runtime)
│   │                             # Stage 1: install deps + run tests
│   │                             # Stage 2: minimal runtime, non-root user
│   └── docker-compose.yml        # Local dev: QA registry (:5001), Prod registry (:5000), app
│
├── scripts/
│   ├── deploy.sh                 # Master deployment script (see below)
│   └── test-local.sh             # Run the FULL pipeline end-to-end locally
│
├── .github/
│   └── workflows/
│       ├── ci.yml                # CI: test → build → push to QA ECR
│       ├── cd.yml                # CD: gate → approve → build → deploy to EKS prod
│       ├── rollback.yml          # Emergency rollback (manual trigger)
│       └── terraform.yml         # Infra changes via Terraform
│
├── k8s/
│   ├── base/                     # Shared Kubernetes manifests (Kustomize base)
│   │   ├── deployment.yaml       # Deployment + Service + ServiceAccount
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── qa/                   # QA: 1 replica, QA image, qa namespace
│       └── prod/                 # Prod: 3 replicas, HPA, prod image, prod namespace
│
├── terraform/
│   ├── bootstrap/                # Run ONCE first — creates S3 + DynamoDB
│   │   ├── main.tf               # S3 state bucket + DynamoDB lock table
│   │   └── variables.tf
│   ├── main.tf                   # VPC + EKS + ECR + Secrets Manager + IAM
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.hcl               # Remote backend config (fill in after bootstrap)
│   └── environments/
│       ├── qa.tfvars
│       └── prod.tfvars
│
├── docs/
│   └── diagrams/
│       └── architecture.html     # Full interactive architecture diagram
│
├── .dockerignore                 # Keeps build context clean, prevents secret leaks
├── .gitignore                    # Excludes .env files, tfstate, node_modules
├── .env.qa.example               # Template — copy to .env.qa, never commit real file
└── .env.prod.example             # Template — copy to .env.prod
```

---

## Prerequisites

### Local Development

| Tool | Version | Install |
|------|---------|---------|
| Docker | ≥ 24.x | https://docs.docker.com/get-docker/ |
| Docker Compose v2 | ≥ 2.20 | Included with Docker Desktop |
| Bash | ≥ 4.x | macOS: `brew install bash` |
| Node.js | ≥ 20.x | https://nodejs.org or `nvm install 20` |
| curl | any | pre-installed on Linux/macOS |

### AWS / Cloud (for CI/CD and EKS)

| Tool | Install |
|------|---------|
| AWS CLI v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |

---

## Quick Start — Run Locally

This runs the **complete pipeline on your laptop** using local Docker registries. No AWS required.

```bash
# 1. Clone the repository
git clone https://github.com/your-org/smartapps-devops.git
cd smartapps-devops

# 2. Make scripts executable
chmod +x scripts/deploy.sh scripts/test-local.sh

# 3. Run the full automated test
./scripts/test-local.sh
```

**What `test-local.sh` does:**
1. Starts QA registry on `localhost:5001` and Prod registry on `localhost:5000`
2. Copies `.env.qa.example` → `.env.qa` (local config, no auth needed)
3. Runs `deploy.sh --env qa --version 1.0.0` — builds, validates, pushes to QA
4. Verifies the image tag exists in the QA registry
5. Starts the container and curls `/health` — confirms HTTP 200
6. Runs `deploy.sh --env prod --version 1.0.0` — enforces QA gate, pushes to Prod
7. Verifies the Prod image tag exists
8. Runs a rollback simulation
9. Prints the full version history log

**Expected output:**
```
[PASS] Local registries started
[PASS] QA image built and pushed (1.0.0-qa)
[PASS] Health check passed
[PASS] Prod promotion succeeded (QA gate enforced)
[PASS] Rollback simulation complete
```

---

## Step-by-Step: Build, Tag, Push

### The deploy.sh script

`scripts/deploy.sh` is the single entry point for all deployment operations.

#### Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--env` | ✅ | Target environment: `qa` or `prod` |
| `--version` | ✅* | Semantic version: `MAJOR.MINOR.PATCH` |
| `--name` | No | Image name (default: `smartapps-service`) |
| `--file` | No | Dockerfile path (default: `docker/Dockerfile`) |
| `--dry-run` | No | Print actions without executing anything |
| `--rollback` | No | Rollback to last stable version |

*Not required when `--rollback` is used.

#### Build to QA

```bash
# Build image, validate locally, push to QA registry
./scripts/deploy.sh --env qa --version 1.2.0
```

**What happens:**
1. Loads `.env.qa` — gets registry URL and port
2. Resolves full tag: `localhost:5001/smartapps-service:1.2.0-qa`
3. Builds Docker image with `--build-arg APP_VERSION=1.2.0 BUILD_ENV=qa`
4. Starts container on port `18080`, waits, curls `/health` up to 5 times
5. If health check fails → **aborts. Nothing is pushed.**
6. Pushes `1.2.0-qa` and `latest-qa` tags to the QA registry
7. Records `PUSHED` and `STABLE` entries in `.version_history.log`

#### Promote to Production

```bash
# Promote QA image to Production
./scripts/deploy.sh --env prod --version 1.2.0
```

**Additional step for prod:** Before building, the script calls `check_qa_gate()`:
- Queries the QA registry for tag `1.2.0-qa`
- If the tag does not exist → **aborts with a clear error message**
- This prevents pushing directly to Production without going through QA

#### Preview with dry-run

```bash
# See exactly what would happen — nothing is executed
./scripts/deploy.sh --env prod --version 1.2.0 --dry-run
```

#### Semantic versioning

All image tags follow the pattern `{version}-{environment}`:

```
1.2.0-qa    → QA registry (port 5001 local / ECR repo-qa on AWS)
1.2.0-prod  → Prod registry (port 5000 local / ECR repo-prod on AWS)
latest-qa   → Most recent QA build (convenience alias)
latest-prod → Most recent Prod build
rollback-1722345600 → Auto-generated rollback tag (Unix timestamp)
```

---

## Environment Separation & Secrets

### How configuration is separated

| Item | QA | Production |
|------|----|------------|
| Registry port (local) | `5001` | `5000` |
| ECR repo (AWS) | `*-qa` | `*-prod` |
| K8s namespace | `qa` | `prod` |
| EKS node type | `t3.small` SPOT | `t3.medium` ON-DEMAND |
| NAT Gateway | Single (cost saving) | Multi-AZ (HA) |
| Secrets path | `/smartapps/qa/config` | `/smartapps/prod/config` |

### How credentials are handled

**Rule: Credentials are NEVER stored in scripts, Dockerfiles, or committed files.**

| Context | How credentials are injected |
|---------|------------------------------|
| Local dev | `.env.qa` / `.env.prod` — sourced at runtime, git-ignored |
| GitHub Actions | OIDC: GitHub assumes an AWS IAM role — no static keys |
| Kubernetes pods | IRSA: pods get short-lived tokens via AWS OIDC provider |
| AWS Secrets Manager | App reads secrets at runtime via IAM role |

**Setup for local development:**
```bash
# Copy templates (already safe — no real values)
cp .env.qa.example .env.qa
cp .env.prod.example .env.prod


```

---

## Rollback Workflow

### When to roll back

- Deployment caused production errors or regressions
- Health checks failing on live pods
- Business decision to revert a release

### Option 1: GitHub Actions (recommended — audited)

```
GitHub → Actions → Rollback workflow → Run workflow
  Environment: prod
  Strategy: kubectl-undo   ← fastest, uses existing ReplicaSet
  Target version: (leave blank for kubectl-undo)
```

This is the preferred method because it creates an audit trail in GitHub Actions history.

### Option 2: deploy.sh (CLI)

```bash
./scripts/deploy.sh --env prod --rollback
```

**What happens:**
1. Reads `scripts/.version_history.log`
2. Finds the last entry with `STATUS=STABLE` for `ENV=prod`
3. Pulls that image from the registry
4. Re-tags it as `rollback-{timestamp}` and pushes (audit trail)
5. Prints the `kubectl set image` command to complete the K8s update

### Option 3: kubectl directly (fastest — under 60 seconds)

```bash
# Revert to the previous ReplicaSet (no image pull needed)
kubectl rollout undo deployment/smartapps-service --namespace prod

# Check rollback status
kubectl rollout status deployment/smartapps-service --namespace prod

# Verify active image
kubectl get deployment/smartapps-service -n prod \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### Version history log

Every deploy.sh invocation appends to `scripts/.version_history.log`:

```
2025-06-01T08:00:00Z | ENV=qa   | IMAGE=localhost:5001/smartapps-service:1.2.0-qa   | STATUS=PUSHED
2025-06-01T08:01:00Z | ENV=qa   | IMAGE=localhost:5001/smartapps-service:1.2.0-qa   | STATUS=STABLE
2025-06-01T09:00:00Z | ENV=prod | IMAGE=localhost:5000/smartapps-service:1.2.0-prod | STATUS=PUSHED
2025-06-01T09:02:00Z | ENV=prod | IMAGE=localhost:5000/smartapps-service:1.2.0-prod | STATUS=STABLE
2025-06-02T10:00:00Z | ENV=prod | IMAGE=localhost:5000/smartapps-service:1.3.0-prod | STATUS=PUSHED
2025-06-02T10:05:00Z | ENV=prod | IMAGE=localhost:5000/smartapps-service:1.2.0-prod | STATUS=ROLLBACK
```

In CI/CD, ECR image tags themselves serve as the version history — you can always look up any past tag in the ECR console.

---

## GitHub Actions CI/CD

### Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | Push to `main` / PR | Test → Build → Push to QA ECR |
| `cd.yml` | Manual / Release | QA Gate → Approve → Push Prod → Deploy EKS |
| `rollback.yml` | Manual only | Emergency rollback |
| `terraform.yml` | Changes to `terraform/` | Plan / Apply AWS infra |

### Setting up GitHub Secrets

Go to: **Repository → Settings → Secrets and variables → Actions**

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN_QA` | ARN of the IAM role for QA (output from Terraform) |
| `AWS_ROLE_ARN_PROD` | ARN of the IAM role for Production |
| `AWS_REGION` | e.g. `eu-west-1` |
| `ECR_REGISTRY` | e.g. `123456789012.dkr.ecr.eu-west-1.amazonaws.com` |
| `EKS_CLUSTER_QA` | EKS cluster name for QA |
| `EKS_CLUSTER_PROD` | EKS cluster name for Production |

### Setting up Environment Protection (Production Approval Gate)

1. Go to **Repository → Settings → Environments**
2. Click **New environment** → name it `production`
3. Enable **Required reviewers** → add `devops-lead` and `platform-team`
4. Set **Deployment branches** → `main` only

This means the CD workflow will pause at the `deploy-prod` job and wait for a human to click **Approve** before continuing.

### OIDC: How GitHub Actions authenticates to AWS (no static keys)

The CI/CD workflow uses OIDC to assume an AWS IAM role. This means:
- No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` stored anywhere
- GitHub gets a short-lived token (15 minutes) per workflow run
- AWS CloudTrail logs every action with the full GitHub context

**One-time AWS setup:**
```bash
# Create the OIDC provider in AWS (run once per account)
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list <OIDC_THUMBPRINT>
```

The Terraform IAM module handles this automatically when you provision the infrastructure.

---

## Terraform — Bootstrap Remote State

**Run this ONCE before any other Terraform command.**

The bootstrap creates:
- **S3 bucket** — stores all Terraform state files (encrypted, versioned)
- **DynamoDB table** — prevents concurrent state modifications (locking)

```bash
cd terraform/bootstrap

# Initialize with local backend (state stored on disk — only for bootstrap)
terraform init

# Preview what will be created
terraform plan

# Create the S3 bucket and DynamoDB table
terraform apply
```

**After apply completes**, you will see output like:

```
backend_bucket = "smartapps-terraform-state-123456789012"
lock_table     = "smartapps-tf-locks"
aws_region     = "eu-west-1"

backend_hcl_snippet = <<EOT
  bucket         = "smartapps-terraform-state-123456789012"
  region         = "eu-west-1"
  dynamodb_table = "smartapps-tf-locks"
  encrypt        = true
EOT
```

Copy those values into `terraform/backend.hcl`:

```hcl
# terraform/backend.hcl
bucket         = "smartapps-terraform-state-123456789012"
region         = "eu-west-1"
dynamodb_table = "smartapps-tf-locks"
encrypt        = true
```

### Why S3 + DynamoDB?

| Concern | Solution |
|---------|----------|
| Two engineers run `terraform apply` at the same time | DynamoDB lock prevents concurrent writes |
| State file accidentally deleted | S3 versioning — restore any previous version |
| State file contains sensitive values (IPs, ARNs) | S3 server-side encryption (AES256) |
| State bucket accidentally destroyed | `lifecycle { prevent_destroy = true }` on both resources |
| Cost | DynamoDB `PAY_PER_REQUEST` — near-zero cost for lock table |

---

## Terraform — AWS Infrastructure

After bootstrap is complete, provision the full AWS infrastructure:

```bash
cd terraform

# QA environment
terraform init \
  -backend-config="backend.hcl" \
  -backend-config="key=qa/terraform.tfstate"

terraform plan  -var-file="environments/qa.tfvars"
terraform apply -var-file="environments/qa.tfvars"

# Production environment (separate state key)
terraform init \
  -backend-config="backend.hcl" \
  -backend-config="key=prod/terraform.tfstate" \
  -reconfigure

terraform plan  -var-file="environments/prod.tfvars"
terraform apply -var-file="environments/prod.tfvars"
```

**What gets created:**

| Resource | QA | Production |
|----------|----|------------|
| VPC | `10.1.0.0/16`, 3 AZs | `10.2.0.0/16`, 3 AZs |
| NAT Gateway | 1 (cost saving) | 3 (one per AZ — HA) |
| EKS Cluster | `smartapps-eks-qa` v1.29 | `smartapps-eks-prod` v1.29 |
| EKS Nodes | 1–3 × t3.small SPOT | 2–6 × t3.medium ON-DEMAND |
| ECR Repo | `smartapps-service-qa` | `smartapps-service-prod` |
| Secrets | `/smartapps/qa/app-config` | `/smartapps/prod/app-config` |
| IAM Role | `smartapps-jenkins-qa` | `smartapps-jenkins-prod` |

**After apply — configure kubectl:**
```bash
# The exact command is in terraform output
terraform output kubeconfig_command
# → aws eks update-kubeconfig --name smartapps-eks-qa --region eu-west-1
```

---

## Kubernetes Manifests

Manifests use **Kustomize** — a base layer shared by QA and Prod, with environment-specific patches applied on top.

```bash
# Deploy to QA namespace
kubectl apply -k k8s/overlays/qa

# Deploy to Production namespace
kubectl apply -k k8s/overlays/prod

# Preview what would be applied (dry-run)
kubectl kustomize k8s/overlays/prod

# Check rollout status
kubectl rollout status deployment/smartapps-service --namespace prod

# View running pods
kubectl get pods -n prod -l app=smartapps-service

# View HPA (production only)
kubectl get hpa -n prod
```

---

## Health Checks & Validation

### Three layers of health checking

**1. Inside the Docker image (HEALTHCHECK directive):**
```dockerfile
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:8080/health || exit 1
```
Check with: `docker ps` → see `(healthy)` or `(unhealthy)`

**2. deploy.sh validation (before every push):**
```bash
# Automatic — runs every time deploy.sh is called
# Spins up container on :18080, curls /health up to 5 times
# If any attempt fails: image is NOT pushed, script exits 1
```

**3. Kubernetes probes:**
```yaml
livenessProbe:   httpGet /health  → restart pod if app hangs
readinessProbe:  httpGet /ready   → remove from load balancer if not ready
```

### Manual health check

```bash
# Local container
curl http://localhost:8080/health

# Expected response:
# {"status":"healthy","service":"smartapps-service","version":"1.2.0","env":"qa","timestamp":"2025-06-01T09:00:00.000Z"}

# Kubernetes pod (via port-forward)
kubectl port-forward svc/smartapps-service 8080:80 --namespace qa
curl http://localhost:8080/health
```

---

## QA → Production Promotion Checklist

Before every production deployment, verify all of these:

- [ ] QA image exists in ECR: `aws ecr describe-images --repository-name smartapps-service-qa --image-ids imageTag=X.Y.Z-qa`
- [ ] ECR vulnerability scan: 0 CRITICAL findings
- [ ] Unit tests pass in CI (green check on latest commit)
- [ ] Health check passes in QA environment
- [ ] Smoke test verified against live QA pods
- [ ] QA sign-off from tester or tech lead
- [ ] GitHub Environment approval granted by `devops-lead` or `platform-team`
- [ ] Rollback plan confirmed: last STABLE tag known, `kubectl rollout undo` tested in QA

---

## Security Best Practices Applied

| Practice | Implementation |
|----------|----------------|
| No static AWS credentials | OIDC: GitHub Actions assumes IAM role via short-lived tokens |
| No secrets in code | `.env.*` files are git-ignored; Secrets Manager for runtime values |
| Non-root container | `USER appuser` in Dockerfile — container cannot escalate to root |
| Image vulnerability scanning | ECR `scan_on_push = true` — scans every pushed image |
| Least-privilege IAM | Separate IAM roles for QA and Prod; scoped to specific ECR repos |
| State file security | S3 AES256 encryption + `block_public_access = true` |
| Prevent accidental deletion | `lifecycle { prevent_destroy = true }` on S3 + DynamoDB |
| No secrets in Docker image | `--build-arg` values are available at build time only; not in final layer |
| No credentials in K8s manifests | IRSA: pods use service account + IAM role annotation |
| Human gate for production | GitHub Environment with required reviewers |

---

## Troubleshooting

### `REGISTRY_URL is not set`
```bash
# You haven't created your .env file
cp .env.qa.example .env.qa
# Then fill in REGISTRY_URL at minimum
```

### `QA image does not exist` error on prod deploy
```bash
# You must build QA first
./scripts/deploy.sh --env qa --version 1.2.0
# Then retry prod
./scripts/deploy.sh --env prod --version 1.2.0
```

### Health check fails during deploy
```bash
# Check what the container is actually doing
docker run --rm -p 18080:8080 -e APP_ENV=qa localhost:5001/smartapps-service:1.2.0-qa
# In another terminal:
docker logs $(docker ps -q --filter "ancestor=localhost:5001/smartapps-service:1.2.0-qa")
```

### Local registry not reachable
```bash
# Start registries with docker compose
docker compose -f docker/docker-compose.yml up -d registry-qa registry-prod

# Verify they are running
curl http://localhost:5001/v2/
curl http://localhost:5000/v2/
# Should return: {}
```

### Terraform state lock stuck
```bash
# If a previous run crashed and left a lock
terraform force-unlock <LOCK_ID>
# Get the LOCK_ID from the error message
```

### EKS kubectl access denied
```bash
# Refresh kubeconfig
aws eks update-kubeconfig --name smartapps-eks-qa --region eu-west-1
# Verify
kubectl auth can-i get pods --namespace qa
```

---

*SmartApps International — DevOps Case Study | Author: Nelson Ngumo*
# smartapps-devops
