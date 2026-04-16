# Architecture — Amazon EKS

## Components

### Falcon Operator

The Falcon Operator is a Kubernetes Operator (controller) deployed as a Deployment in the `falcon-operator` namespace. It watches for Falcon custom resources (`FalconDeployment`, `FalconNodeSensor`, etc.) and reconciles the cluster state to match the desired spec.

**Installed from:** `quay.io/crowdstrike/falcon-operator`

### FalconDeployment (CRD)

`FalconDeployment` is an umbrella CRD that manages the lifecycle of all Falcon security components on a cluster through a single manifest. Child components inherit the `falcon_api` and `falcon` global settings from the FalconDeployment, with per-component overrides available under `falconNodeSensor`, `falconAdmission`, and `falconImageAnalyzer`.

### FalconNodeSensor

A `FalconNodeSensor` resource tells the operator to deploy a privileged kernel-mode DaemonSet to every qualifying EC2 worker node. The sensor captures system calls in real time, providing EDR, NGAV, and managed threat hunting capabilities at the kernel level.

- **Namespace:** `falcon-system`
- **Workload type:** DaemonSet (one pod per node)
- **Runs as:** Privileged
- **Backend:** BPF (default) or kernel module
- **EKS node support:** Managed node groups, self-managed node groups, Bottlerocket, Amazon Linux 2, Ubuntu
- **Fargate:** Not supported — use FalconContainer (sidecar injection) instead

### FalconAdmission (KAC)

The Kubernetes Admission Controller provides:
- **Visibility** — Resource Watcher (real-time) and Resource Snapshots (periodic)
- **Protection** — Admission webhook validates resource requests before the API server processes them, blocking objects with Kubernetes Indicators of Misconfiguration (IOMs)

- **Namespace:** `falcon-kac`
- **Workload type:** Deployment (2 replicas by default)

### FalconImageAnalyzer (IAR)

Image Assessment at Runtime assesses container images as they run, extending security beyond pre-runtime scanning. It feeds assessment data to the Falcon console for SBOM generation and runtime policy enforcement.

- **Namespace:** `falcon-iar`
- **Workload type:** Deployment

## EKS-Specific Network Requirements

### Outbound HTTPS from EKS nodes / VPC

| Endpoint | Purpose |
|---|---|
| `api.crowdstrike.com` (us-1) | API calls (image pull auth, policy lookups) |
| `api.us-2.crowdstrike.com` | US-2 cloud |
| `api.eu-1.crowdstrike.com` | EU-1 cloud |
| `api.laggar.gcw.crowdstrike.com` | us-gov-1 cloud |
| `registry.crowdstrike.com` | Container image pull (unless using ECR mirror) |
| `ts01-b.cloudsink.net` (or cloud-specific) | Sensor telemetry streaming |

### Private VPC / No Public Egress

If your EKS cluster runs in a private VPC without public internet access:

1. **Mirror sensor images to ECR** — set `registry.type: ecr` in the FalconDeployment spec and configure an IRSA role with ECR pull permissions.
2. **Use a VPC endpoint or proxy** for CrowdStrike API calls, or configure `falcon.aph` / `falcon.app` in the manifest.
3. Ensure VPC security groups allow HTTPS (443) outbound to the CrowdStrike cloud region endpoints above (or to your proxy).

## IAM / IRSA for ECR Mirroring

If mirroring Falcon sensor images to ECR, the operator's service account needs an IAM role with:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
```

Associate the role via IRSA:

```bash
eksctl create iamserviceaccount \
  --name falcon-operator-controller-manager \
  --namespace falcon-operator \
  --cluster <cluster-name> \
  --region <region> \
  --attach-policy-arn arn:aws:iam::<account-id>:policy/FalconOperatorECRPolicy \
  --approve \
  --override-existing-serviceaccounts
```

Then annotate the service account in your FalconDeployment spec:

```yaml
falconNodeSensor:
  node:
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::<account-id>:role/falcon-operator-role"
```

## Secrets Architecture

```
┌──────────────────────────────────────────────────────┐
│  AWS Secrets Manager / Parameter Store               │
│  (recommended for production EKS environments)       │
└──────────────────┬───────────────────────────────────┘
                   │  syncs via External Secrets Operator
                   │  or Secrets Store CSI Driver
                   ▼
┌──────────────────────────────────────────────────────┐
│  Kubernetes Secret "falcon-secrets"                  │
│  Namespace: falcon-operator                          │
│                                                      │
│  Keys:                                               │
│    falcon-client-id        → API client ID           │
│    falcon-client-secret    → API client secret       │
│    falcon-cid              → CID with checksum       │
└──────────────────────────────────────────────────────┘
                   │  referenced by
                   ▼
┌──────────────────────────────────────────────────────┐
│  FalconDeployment spec                               │
│    falconSecret:                                     │
│      enabled: true                                   │
│      namespace: falcon-operator                      │
│      secretName: falcon-secrets                      │
└──────────────────────────────────────────────────────┘
```

Credentials are **never stored in the FalconDeployment manifest** itself, which makes this pattern safe for GitOps (manifests can be committed without exposing secrets).

## Sensor Lifecycle Flow on EKS

```
aws eks update-kubeconfig && kubectl apply -f falcondeployment.yaml
         │
         ▼
Falcon Operator detects FalconDeployment
         │
         ├── Reads API credentials from Kubernetes secret
         ├── Authenticates to CrowdStrike API
         ├── Pulls sensor image (CrowdStrike registry or ECR mirror)
         ├── Creates FalconNodeSensor resource
         ├── Creates DaemonSet in falcon-system namespace
         │     └── One pod per EC2 node (skips Fargate nodes)
         └── Creates KAC and IAR deployments

Every 24 hours:
         │
         ├── Operator checks Falcon API for policy-resolved version
         ├── If new version: reconcile → DaemonSet rolling update (node by node)
         └── If same version (autoUpdate: normal): no action
```
