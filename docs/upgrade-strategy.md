# Centralized Upgrade Strategy

## Goal

All sensor version decisions for Kubernetes clusters are governed by a single source of truth: the **Falcon console Sensor Update Policy**. No CI pipeline, no Helm values file, and no GitOps diff is required to roll a sensor update.

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                    Falcon Console                        │
│                                                          │
│  Sensor Update Policy: "k8s-prod"                        │
│    Version: Auto - N-2  (currently resolves to 7.18.x)  │
│    Platform: Linux                                       │
└────────────────────┬────────────────────────────────────┘
                     │
                     │  API: Sensor Update Policies: Read
                     │  (checked every 24 hours)
                     ▼
┌─────────────────────────────────────────────────────────┐
│                  Falcon Operator                         │
│                                                          │
│  FalconDeployment spec:                                  │
│    node.advanced.autoUpdate:   normal                    │
│    node.advanced.updatePolicy: "k8s-prod"                │
│                                                          │
│  On version change detected:                             │
│    → Reconcile FalconNodeSensor                          │
│    → DaemonSet rolls to new sensor image                 │
└─────────────────────────────────────────────────────────┘
```

### The 24-Hour Reconcile Loop

1. The operator wakes up every 24 hours (configurable via `--sensor-auto-update-interval`).
2. It calls the Falcon API with the `Sensor Update Policies: Read` scope.
3. It looks up the policy named in `updatePolicy` to find the currently recommended sensor version for that policy's version setting (e.g., `Auto - N-2`).
4. If the resolved version differs from what is currently deployed:
   - **`autoUpdate: normal`** — triggers a reconcile (DaemonSet update).
   - **`autoUpdate: force`** — triggers a reconcile on every check, regardless.
   - **`autoUpdate: off`** — no action.
5. The DaemonSet rolls the new sensor image node by node using Kubernetes rolling update semantics.

## Environment Promotion Model

Use separate named policies for each environment tier, and reference them in the corresponding cluster's `falcondeployment.yaml`:

```
Dev clusters        → updatePolicy: "k8s-dev"       (Auto - Latest)
                           │  New sensor released
                           ▼  Operator picks it up within 24h
Staging clusters    → updatePolicy: "k8s-staging"   (Auto - N-1)
                           │  Tested in dev, now in staging
                           ▼
Production clusters → updatePolicy: "k8s-prod"      (Auto - N-2)
```

To promote a sensor version from staging to production:
1. Go to the Falcon console.
2. Find the `k8s-prod` policy.
3. If using a fixed version: update the pinned build number.
4. If using `Auto - N-2`: no action needed — production trails staging by one version automatically.

## Rollback

The Falcon console supports reverting to any sensor released in the last **180 days** (regular sensors) or **365 days** (LTS sensors).

To roll back a Kubernetes cluster:
1. In the Falcon console, update the relevant policy's version to a specific previous build.
2. The operator picks up the change on the next 24-hour check cycle.
3. The DaemonSet rolls back automatically.

For immediate rollback (without waiting for the next cycle), manually patch the version in the FalconDeployment:
```bash
kubectl edit falcondeployment
# Set falconNodeSensor.node.version to the target version
# Remove advanced.updatePolicy temporarily to prevent the operator
# from overriding your pinned version on the next cycle
```

## DaemonSet Upgrade Behavior

The operator uses the Kubernetes DaemonSet rolling update strategy. Nodes are updated one at a time (by default). The Falcon sensor process itself performs an in-place update with **no host restart required**.

> **Note for sensor versions 7.33 and earlier:** DaemonSet upgrades are blocked if the current sensor update policy has **Uninstall and maintenance protection** enabled. Before upgrading, move the affected host group to a policy with that setting disabled.

## API Scope Requirements

| Feature | Required API Scope |
|---|---|
| Pull sensor image from CrowdStrike registry | Falcon Images Download: Read |
| Access sensor deployment packages | Sensor Download: Read |
| `autoUpdate` + `updatePolicy` features | **Sensor Update Policies: Read** |

If `Sensor Update Policies: Read` is missing, the operator silently ignores `autoUpdate` and `updatePolicy`. Verify scopes in the Falcon console under **API clients and keys**.
