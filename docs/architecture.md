# Architecture

## Components

### Falcon Operator

The Falcon Operator is a Kubernetes Operator (controller) deployed as a Deployment in the `falcon-operator` namespace. It watches for Falcon custom resources (`FalconDeployment`, `FalconNodeSensor`, etc.) and reconciles the cluster state to match the desired spec.

**Installed from:** `quay.io/crowdstrike/falcon-operator` (or Red Hat registry for OpenShift)

### FalconDeployment (CRD)

`FalconDeployment` is an umbrella CRD that manages the lifecycle of all Falcon security components on a cluster through a single manifest. Child components inherit the `falcon_api` and `falcon` global settings from the FalconDeployment, with per-component overrides available under `falconNodeSensor`, `falconAdmission`, and `falconImageAnalyzer`.

### FalconNodeSensor

A `FalconNodeSensor` resource tells the operator to deploy a privileged kernel-mode DaemonSet to every qualifying worker node. The sensor captures system calls in real time, providing EDR, NGAV, and managed threat hunting capabilities at the kernel level.

- **Namespace:** `falcon-system`
- **Workload type:** DaemonSet (one pod per node)
- **Runs as:** Privileged
- **Backend:** BPF (default) or kernel module

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

## Network Requirements

The operator and sensors require outbound HTTPS access to your CrowdStrike cloud region:

| Endpoint | Purpose |
|---|---|
| `api.crowdstrike.com` (us-1) | API calls (image pull auth, policy lookups) |
| `api.us-2.crowdstrike.com` | US-2 cloud |
| `api.eu-1.crowdstrike.com` | EU-1 cloud |
| `api.laggar.gcw.crowdstrike.com` | us-gov-1 cloud |
| `registry.crowdstrike.com` | Container image pull |
| `ts01-b.cloudsink.net` (or equivalent) | Sensor telemetry streaming |

If your cluster uses a proxy, configure `falcon.apd`, `falcon.aph`, and `falcon.app` in the FalconDeployment spec.

## Secrets Architecture

```
┌──────────────────────────────────────────────────────┐
│  External Secret Store                                │
│  (Vault / AWS Secrets Manager / External Secrets)    │
└──────────────────┬───────────────────────────────────┘
                   │  syncs to
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

## Sensor Lifecycle Flow

```
kubectl apply -f falcondeployment.yaml
         │
         ▼
Falcon Operator detects FalconDeployment
         │
         ├── Reads API credentials from Kubernetes secret
         ├── Authenticates to CrowdStrike API
         ├── Pulls sensor image from CrowdStrike registry
         ├── Creates FalconNodeSensor resource
         ├── Creates DaemonSet in falcon-system namespace
         └── Creates KAC and IAR deployments

Every 24 hours:
         │
         ├── Operator checks Falcon API for policy-resolved version
         ├── If new version: reconcile → DaemonSet rolling update
         └── If same version (autoUpdate: normal): no action
```
