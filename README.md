# Falcon Sensor Deployment via Falcon Operator

This repository provides production-ready Kubernetes manifests and supporting documentation for deploying the CrowdStrike Falcon sensor using the **Falcon Operator**, with a centralized upgrade strategy driven by **Falcon Sensor Update Policies**.

## Overview

The Falcon Operator uses Custom Resource Definitions (CRDs) to install, configure, and lifecycle-manage Falcon security components on Kubernetes clusters. This repo focuses on the **FalconNodeSensor** (DaemonSet) deployment model and wires it to a named Sensor Update Policy in the Falcon console so that all version governance lives in one place — the Falcon platform — rather than scattered across CI pipelines or manifest files.

```
Falcon Console (Sensor Update Policy)
         │
         │  Sensor Update Policies: Read (API scope)
         ▼
   Falcon Operator  ──────────────────────────────────────┐
         │  node.advanced.updatePolicy = "k8s-prod"       │
         │  node.advanced.autoUpdate   = normal            │
         ▼                                                 │
   FalconDeployment CRD                                    │
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
| Sensor type | FalconNodeSensor (kernel DaemonSet) | Full kernel-level visibility on worker nodes |
| Version governance | `node.advanced.updatePolicy` → named Falcon policy | Centralizes upgrade decisions in the Falcon console; no manifest changes needed to roll a new sensor |
| Secrets management | Kubernetes Secret + `falconSecret` block | API credentials never stored in manifests or source control |
| Auto-update mode | `autoUpdate: normal` | Operator reconciles only when a new version is detected via the policy |

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

### Kubernetes Requirements
| Platform | Minimum Version |
|---|---|
| Amazon EKS | 1.17+ |
| Azure AKS | 1.18+ |
| Google GKE | 1.18+ |
| Red Hat OpenShift | 4.10+ |
| Self-managed | 1.21+ |

### Tools
- `kubectl` (cluster admin access)
- `curl`, `jq` (for helper scripts)
- `oc` (OpenShift only)

## Repository Structure

```
.
├── README.md
├── operator/
│   └── falcon-operator.yaml          # Operator controller deployment (versioned)
├── sensors/
│   ├── node-sensor/
│   │   ├── namespace.yaml            # falcon-system namespace
│   │   ├── secret.yaml               # Kubernetes secret template (gitignore the populated version)
│   │   └── falcondeployment.yaml     # Primary FalconDeployment CRD manifest
│   └── container-sensor/
│       └── falcondeployment-container.yaml  # Alternative: sidecar injection deployment
├── update-policies/
│   └── sensor-update-policy-guide.md # How to configure the Falcon console policy
├── docs/
│   ├── architecture.md               # Architecture deep-dive
│   ├── upgrade-strategy.md           # Centralized upgrade strategy explained
│   └── troubleshooting.md            # Common issues and kubectl diagnostic commands
├── scripts/
│   ├── install.sh                    # End-to-end install helper
│   └── verify.sh                     # Post-install verification
└── .github/
    └── workflows/
        └── validate-manifests.yaml   # CI: kubeval + dry-run validation
```

## Quick Start

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

Update `sensors/node-sensor/falcondeployment.yaml` with your policy name and cloud region, then:

```bash
kubectl apply -f sensors/node-sensor/falcondeployment.yaml
```

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
