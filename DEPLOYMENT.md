# FoodDash — Deployment Guide

This document covers the full deployment setup for the FoodDash food-ordering web app — from local Docker run to a production Kubernetes cluster on AWS EKS.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Local Development with Docker](#local-development-with-docker)
- [Kubernetes Manifests](#kubernetes-manifests)
- [CI/CD Pipeline](#cicd-pipeline)
- [GitHub Secrets Setup](#github-secrets-setup)
- [AWS EKS Setup](#aws-eks-setup)
- [Deploying Manually](#deploying-manually)
- [Rollback](#rollback)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
Developer pushes to main
        │
        ▼
┌───────────────────┐
│  GitHub Actions   │
│                   │
│  1. Build & Test  │  Validate HTML/CSS/JS source files
│  2. Docker Build  │  Build image → push to Docker Hub
│  3. K8s Deploy    │  kubectl apply → rolling update → health check
└───────────────────┘
        │
        ▼
┌───────────────────────────────────┐
│          AWS EKS Cluster          │
│                                   │
│  Namespace: food-app              │
│  ┌─────────────────────────────┐  │
│  │  Deployment (2–10 replicas) │  │
│  │  ┌──────────┐ ┌──────────┐  │  │
│  │  │  Pod 1   │ │  Pod 2   │  │  │
│  │  │ Nginx+   │ │ Nginx+   │  │  │
│  │  │ food-app │ │ food-app │  │  │
│  │  └──────────┘ └──────────┘  │  │
│  └─────────────────────────────┘  │
│  HPA: auto-scales on CPU/memory   │
│  Service: LoadBalancer (port 80)  │
└───────────────────────────────────┘
        │
        ▼
    End Users
```

---

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Docker | 24+ | https://docs.docker.com/get-docker |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools |
| AWS CLI | 2.x | https://aws.amazon.com/cli |
| eksctl | latest | https://eksctl.io |
| Git | 2.x | https://git-scm.com |

---

## Project Structure

```
food-APP/
├── index.html                      # App entry point
├── pages/                          # All HTML pages
├── css/                            # Stylesheets
├── js/                             # JavaScript files
├── data/                           # Restaurant data
├── assets/                         # Icons and images
│
├── Dockerfile                      # 2-stage build (Node build + Nginx serve)
├── nginx.conf                      # Custom Nginx config
├── .dockerignore                   # Files excluded from Docker build
│
├── k8s/                            # Kubernetes manifests
│   ├── namespace.yaml              # food-app namespace
│   ├── deployment.yaml             # Deployment with 2 replicas
│   ├── service.yaml                # LoadBalancer service
│   ├── ingress.yaml                # Ingress (optional, needs Ingress controller)
│   └── hpa.yaml                    # Horizontal Pod Autoscaler
│
└── .github/
    └── workflows/
        └── deploy.yml              # CI/CD pipeline
```

---

## Local Development with Docker

### Build the image

```bash
docker build -t food-app .
```

### Run locally

```bash
docker run -d -p 8080:80 --name food-app food-app
```

Open http://localhost:8080 in your browser.

### Stop and remove

```bash
docker stop food-app && docker rm food-app
```

### Rebuild after changes

```bash
docker build --no-cache -t food-app .
docker run -d -p 8080:80 --name food-app food-app
```

---

## Kubernetes Manifests

### namespace.yaml
Creates an isolated `food-app` namespace for all resources.

### deployment.yaml
- **2 replicas** by default (scaled by HPA)
- **RollingUpdate** strategy — zero downtime deployments
- `maxSurge: 1` — one extra pod during updates
- `maxUnavailable: 0` — never removes a pod before a new one is ready
- Liveness and readiness probes on port 80
- Resource requests: 50m CPU / 64Mi memory
- Resource limits: 200m CPU / 128Mi memory
- Pod anti-affinity to spread replicas across nodes

### service.yaml
- Type: `LoadBalancer` — provisions an AWS ELB automatically
- Exposes port 80 externally

### hpa.yaml
- Min replicas: **2**
- Max replicas: **10**
- Scales up when CPU > 70% or memory > 80%

### ingress.yaml
Optional — use when you have an Nginx Ingress Controller installed.
Update `host: food-app.example.com` with your actual domain.

---

## CI/CD Pipeline

The pipeline has 3 jobs that run in sequence:

### Job 1 — Build & Test
Triggered on every push to `main`.
- Checks all required HTML/CSS/JS files exist
- Validates HTML structure (`<html>`, `<body>` tags)
- Checks JS syntax with `node --check`
- Verifies CSS files are non-empty

### Job 2 — Docker Build & Push
Runs only if Job 1 passes.
- Builds the Docker image using the 2-stage Dockerfile
- Tags the image with the git commit SHA and `latest`
- Pushes to Docker Hub
- Uses GitHub Actions cache to speed up builds

### Job 3 — Deploy to Kubernetes
Runs only if Job 2 passes.
- Configures `kubectl` to connect to your EKS cluster
- Applies all `k8s/` manifests
- Updates the deployment with the new image tag
- Waits for the rolling update to complete (5 min timeout)
- Prints pod/service/HPA status
- **Auto-rollbacks** to the previous version if the deployment fails

---

## GitHub Secrets Setup

Go to: `https://github.com/YOUR_USERNAME/food-App/settings/secrets/actions`

Add these secrets:

| Secret | Description | Example |
|---|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username | `johndoe` |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not password) | `dckr_pat_xxx...` |
| `AWS_ACCESS_KEY_ID` | AWS IAM user access key | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | AWS IAM user secret key | `wJalrXUtnFEMI/K7MDENG/...` |
| `AWS_REGION` | AWS region where EKS lives | `us-east-1` |
| `EKS_CLUSTER_NAME` | Name of your EKS cluster | `food-app-cluster` |

### How to get a Docker Hub token
1. Log in to https://hub.docker.com
2. Account Settings → Security → New Access Token
3. Name it `github-actions`, set permissions to Read/Write
4. Copy the token — it's only shown once

### How to get AWS access keys
1. AWS Console → IAM → Users → your user
2. Security credentials → Create access key
3. Use case: Application running outside AWS
4. Copy both keys — secret is only shown once

### Required IAM permissions for the AWS user
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster",
        "eks:ListClusters"
      ],
      "Resource": "*"
    }
  ]
}
```
Also attach the AWS managed policy: `AmazonEKSClusterPolicy`

---

## AWS EKS Setup

### 1. Create an EKS cluster (if you don't have one)

```bash
eksctl create cluster \
  --name food-app-cluster \
  --region us-east-1 \
  --nodegroup-name workers \
  --node-type t3.small \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 5 \
  --managed
```

This takes 10–15 minutes.

### 2. Configure kubectl locally

```bash
aws eks update-kubeconfig \
  --region us-east-1 \
  --name food-app-cluster
```

### 3. Verify connection

```bash
kubectl get nodes
```

### 4. Update the deployment image

Open `k8s/deployment.yaml` and replace:
```yaml
image: YOUR_DOCKERHUB_USERNAME/food-app:latest
```
with your actual Docker Hub username:
```yaml
image: johndoe/food-app:latest
```

---

## Deploying Manually

If you want to deploy without the pipeline:

```bash
# 1. Build and push the Docker image
docker build -t YOUR_USERNAME/food-app:latest .
docker push YOUR_USERNAME/food-app:latest

# 2. Apply Kubernetes manifests
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml

# 3. Check deployment status
kubectl get pods -n food-app
kubectl get svc  -n food-app

# 4. Get the external URL
kubectl get svc food-app-service -n food-app
# Copy the EXTERNAL-IP from the output
```

---

## Rollback

### Automatic rollback
The CI/CD pipeline automatically rolls back if the deployment fails.

### Manual rollback to previous version

```bash
# Roll back to the previous deployment
kubectl rollout undo deployment/food-app -n food-app

# Roll back to a specific revision
kubectl rollout history deployment/food-app -n food-app
kubectl rollout undo deployment/food-app --to-revision=2 -n food-app
```

---

## Troubleshooting

### Pipeline fails at "Configure kubectl"
- Check `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `EKS_CLUSTER_NAME` secrets are set correctly
- Verify the IAM user has `eks:DescribeCluster` permission

### Pipeline fails at "Docker Build & Push"
- Check `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets
- Make sure the Docker Hub token has Read & Write permissions

### Pods stuck in `Pending`
```bash
kubectl describe pod -n food-app
```
Usually means the cluster has no available nodes. Check node capacity:
```bash
kubectl get nodes
kubectl describe node NODE_NAME
```

### Pods in `CrashLoopBackOff`
```bash
kubectl logs -n food-app deploy/food-app
```
Usually a broken Nginx config or missing files in the image.

### Service has no EXTERNAL-IP
EKS LoadBalancer provisioning takes 2–3 minutes. Run:
```bash
kubectl get svc -n food-app -w
```
and wait for the EXTERNAL-IP to appear.

### Check live pod logs
```bash
kubectl logs -n food-app -l app=food-app --tail=50 -f
```
