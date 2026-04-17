# Falcon Sensor Deployment via Falcon Operator — Amazon EKS

This repository provides production-ready Kubernetes manifests and supporting documentation for deploying the CrowdStrike Falcon sensor on **Amazon EKS** using the **Falcon Operator**, with a centralized upgrade strategy driven by **Falcon Sensor Update Policies**.

## Overview

The Falcon Operator uses Custom Resource Definitions (CRDs) to install, configure, and lifecycle-manage Falcon security components on EKS clusters. This repo focuses on the **FalconNodeSensor** (DaemonSet) deployment model for managed node groups, with the container sensor provided as an alternative for Fargate workloads. Sensor version governance is wired to a named Sensor Update Policy in the Falcon console so all upgrade decisions live in one place — the Falcon platform — rather than scattered across CI pipelines or manifest files.

```
Falcon Console (Sensor Update Policy)
         │
         │  Sensor Update Policies: Read (API scope)
         ▼
   Falcon Operator  ──────────────────────────────────────┐
         │  node.advanced.updatePolicy = "k8s-prod"       │
         │  node.advanced.autoUpdate   = normal           │
         ▼                                                │
   FalconDeployment CRD                                   │
     ├── FalconNodeSensor  (DaemonSet on each node)       │
     ├── FalconAdmission   (Kubernetes Admission KAC)     │
     └── FalconImageAnalyzer (IAR agent)                  │
                                                          │
   All sensor version decisions flow through the          │
   Falcon console policy ─────────────────────────────────┘
```

## Key Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deployment method | Falcon Operator (FalconDeployment CRD) | Single manifest controls all components; GitOps-friendly |
| Sensor type | FalconNodeSensor (kernel DaemonSet) | Full kernel-level visibility on EKS managed/self-managed node groups |
| Version governance | `node.advanced.updatePolicy` → named Falcon policy | Centralizes upgrade decisions in the Falcon console; no manifest changes needed to roll a new sensor |
| Secrets management | Kubernetes Secret + `falconSecret` block | API credentials never stored in manifests or source control |
| Auto-update mode | `autoUpdate: normal` | Operator reconciles only when a new version is detected via the policy |
| Image registry | CrowdStrike registry (default) or ECR mirror | ECR mirror recommended for air-gapped VPCs or strict egress controls |
| Credentials for ECR | IAM Role for Service Account (IRSA) | Avoid long-lived AWS credentials; bind IAM permissions to the operator service account |

> **Fargate note:** FalconNodeSensor requires privileged kernel access and **cannot run on Fargate nodes**. For Fargate workloads, use the container sensor manifest in `sensors/container-sensor/`.

## Prerequisites

### CrowdStrike Subscriptions
One of:
- Falcon Cloud Security with Containers (CNAPP)
- Falcon Cloud Security Runtime Protection
- Falcon for Managed Containers Runtime Protection

### Required API Scopes
Create an API client at **Support and resources > Resources and tools > API clients and keys** with:

| Scope | Permission | Purpose |
|---|---|---|
| Falcon Images Download | Read | Pull sensor image from CrowdStrike registry |
| Sensor Download | Read | Access sensor deployment packages |
| Sensor Update Policies | Read | **Required** for `autoUpdate` + `updatePolicy` features |

### EKS Requirements

- EKS cluster version **1.17 or later**
- Node groups must use **managed or self-managed EC2 nodes** (not Fargate) for FalconNodeSensor
- Worker nodes must run a supported Linux OS (Amazon Linux 2, Bottlerocket, Ubuntu)
- Cluster must have an **OIDC provider** configured if using IRSA for ECR pull credentials

### Tools
- `kubectl` (with cluster-admin access)
- `aws` CLI (configured with appropriate IAM permissions)
- `eksctl` (optional, used in IRSA setup examples)
- `curl`, `jq`

## Repository Structure

```
.
├── README.md
├── operator/
│   └── README.md                          # Operator version pinning instructions
├── sensors/                               # Raw manifests (used by all deploy models)
│   ├── node-sensor/
│   │   ├── namespace.yaml
│   │   ├── secret.yaml                    # Secret template — never commit populated
│   │   └── falcondeployment.yaml          # FalconDeployment with all options documented
│   └── container-sensor/
│       └── falcondeployment-container.yaml  # EKS Fargate sidecar injection alternative
├── deploy/                                # Deployment models — pick one
│   ├── kubectl/
│   │   └── README.md                      # Model 1: imperative kubectl steps
│   ├── scripted/
│   │   └── README.md                      # Model 2: install.sh usage and pipeline integration
│   └── gitops/
│       ├── README.md                      # Model 3: ArgoCD / Flux setup guide
│       ├── kustomize/
│       │   ├── base/                      # Base FalconDeployment (updatePolicy unset)
│       │   └── overlays/
│       │       ├── dev/                   # updatePolicy: k8s-dev   (Auto - Latest)
│       │       ├── staging/               # updatePolicy: k8s-staging (Auto - N-1)
│       │       └── prod/                  # updatePolicy: k8s-prod   (Auto - N-2)
│       ├── argocd/
│       │   └── application.yaml           # ArgoCD Application manifests (one per env)
│       ├── flux/
│       │   └── kustomization.yaml         # Flux GitRepository + Kustomization resources
│       └── external-secrets/
│           └── externalsecret.yaml        # ESO ExternalSecret — syncs from AWS Secrets Manager
├── update-policies/
│   └── sensor-update-policy-guide.md      # How to configure Falcon console policies
├── docs/
│   ├── architecture.md                    # EKS architecture, networking, IRSA
│   ├── upgrade-strategy.md                # Centralized upgrade strategy explained
│   └── troubleshooting.md                 # Common issues and kubectl diagnostics
├── scripts/
│   ├── install.sh                         # End-to-end install helper (Model 2)
│   ├── uninstall.sh                       # Complete removal of Operator and components
│   └── verify.sh                          # Post-install verification
└── .github/
    └── workflows/
        └── validate-manifests.yaml        # CI: YAML validation + credential leak check
```

## Quick Start

There are two ways to deploy: the **automated script** (recommended for first-time installs) or **manual steps** (for GitOps / step-by-step control).

---

### Option A: Automated install with `install.sh`

The script handles kubeconfig, operator install, secret creation, manifest substitution, and verification in one pass.

```bash
# Clone the repo
git clone https://github.com/jmckenzie-cs/falcon-operator-sensor-deployment.git
cd falcon-operator-sensor-deployment

# Set required environment variables
export AWS_REGION="us-east-1"
export EKS_CLUSTER_NAME="my-cluster"
export FALCON_CLIENT_ID="<your-api-client-id>"
export FALCON_CLIENT_SECRET="<your-api-client-secret>"
export FALCON_CID="<your-cid-with-checksum>"

# Optional overrides (defaults shown)
export FALCON_CLOUD_REGION="autodiscover"   # or us-1, us-2, eu-1, us-gov-1
export FALCON_UPDATE_POLICY="k8s-prod"      # exact name of your Sensor Update Policy
export OPERATOR_VERSION="v1.7.0"            # pin to a specific operator release

# Run the installer
bash scripts/install.sh
```

The script will:
1. Run `aws eks update-kubeconfig` and verify cluster-admin access
2. Install the Falcon Operator and wait for it to be ready
3. Create the `falcon-secrets` Kubernetes secret in the `falcon-operator` namespace
4. Apply the FalconDeployment manifest with your policy name and cloud region substituted in
5. Run `scripts/verify.sh` to confirm all components are healthy

---

### Option B: Manual steps

### 0. Clone the repo and configure EKS context

```bash
git clone https://github.com/jmckenzie-cs/falcon-operator-sensor-deployment.git
cd falcon-operator-sensor-deployment

# Update your kubeconfig for the target cluster
aws eks update-kubeconfig --region <region> --name <cluster-name>

# Verify you have cluster-admin
kubectl auth can-i '*' '*' --all-namespaces
```

### 1. Install the Falcon Operator

```bash
OPERATOR_VERSION="v1.7.0"  # Pin to a specific release
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml
```

Verify the operator is running:
```bash
kubectl wait --for=condition=Available deployment/falcon-operator-controller-manager \
  -n falcon-operator --timeout=120s
```

### 2. Create the Kubernetes Secret

```bash
kubectl apply -f sensors/node-sensor/namespace.yaml

kubectl create secret generic falcon-secrets \
  -n falcon-operator \
  --from-literal=falcon-client-id="$FALCON_CLIENT_ID" \
  --from-literal=falcon-client-secret="$FALCON_CLIENT_SECRET" \
  --from-literal=falcon-cid="$FALCON_CID"
```

### 3. Create a Sensor Update Policy in the Falcon Console

See [`update-policies/sensor-update-policy-guide.md`](update-policies/sensor-update-policy-guide.md) for step-by-step instructions. Note the **exact policy name** you assign (e.g., `k8s-prod`) — you will reference it in the manifest.

### 4. Deploy the FalconDeployment

Use `--edit` to open the manifest in your editor before it is applied. Set the two values when the file opens:

- `falcon_api.cloud_region` — your CrowdStrike cloud region (e.g., `us-1`). Leave as `autodiscover` if unsure.
- `node.advanced.updatePolicy` — the **exact name** of the Sensor Update Policy you created in Step 3 (case-sensitive).

```bash
kubectl apply -f sensors/node-sensor/falcondeployment.yaml --edit
```

Save and close the file to apply.

### 5. Verify

```bash
# Operator and sensor status
kubectl get falcondeployment -o wide
kubectl get falconnodesensors -A

# DaemonSet readiness
kubectl get daemonsets.apps -n falcon-system

# Deployed sensor version
kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'
```

## How the Centralized Upgrade Strategy Works

1. **You configure** a Sensor Update Policy in the Falcon console (e.g., `Auto - N-1` for production, `Auto - Latest` for test clusters).
2. **The Falcon Operator** reads that policy name from `node.advanced.updatePolicy` in your FalconDeployment manifest.
3. Every **24 hours** (default), the operator queries the Falcon API (`Sensor Update Policies: Read`) to check whether the policy dictates a new sensor version.
4. If a new version is detected (`autoUpdate: normal`), the operator **automatically reconciles** the DaemonSet to roll out the new sensor image with zero manifest changes.
5. Version rollbacks are handled in the Falcon console — change the policy version, and the operator picks it up on the next check cycle.

See [`docs/upgrade-strategy.md`](docs/upgrade-strategy.md) for full details.

## Uninstall

To remove the Falcon Operator and all deployed components:

```bash
export AWS_REGION="us-east-1"
export EKS_CLUSTER_NAME="my-cluster"
export OPERATOR_VERSION="v1.7.0"

bash scripts/uninstall.sh
```

See [`docs/uninstall.md`](docs/uninstall.md) for manual steps, GitOps considerations, and partial removal options.

## Troubleshooting

See [`docs/troubleshooting.md`](docs/troubleshooting.md) for common issues. Quick diagnostics:

```bash
# Operator logs
kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager

# Check auto-update config
kubectl get falconnodesensor -n falcon-system -o yaml | grep -A 3 advanced

# Check update check interval
kubectl get deployment falcon-operator -n falcon-operator -o yaml | grep sensor-auto-update-interval
```

## References

- [Falcon Operator GitHub](https://github.com/CrowdStrike/falcon-operator)
- [CrowdStrike Falcon Operator Docs](https://falcon.crowdstrike.com/documentation/category/c2d4a7a0/operator)
- [Sensor Update Policies](https://falcon.crowdstrike.com/documentation/page/d2d629cf/sensor-update-policies)
- [Component Configuration Reference](https://falcon.crowdstrike.com/documentation/page/k50c89b4/component-specific-configuration-options)
- [Amazon EKS Documentation](https://docs.aws.amazon.com/eks/latest/userguide/getting-started.html)
- [IAM Roles for Service Accounts (IRSA)](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)
- [Amazon ECR Private Registries](https://docs.aws.amazon.com/AmazonECR/latest/userguide/Registries.html)
