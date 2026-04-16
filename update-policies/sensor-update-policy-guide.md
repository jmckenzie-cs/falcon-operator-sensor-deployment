# Sensor Update Policy — Falcon Console Configuration Guide

This document explains how to create and name Sensor Update Policies in the Falcon console so that the Falcon Operator can use them to govern sensor versions on your Kubernetes clusters.

## Why a Named Update Policy?

The Falcon Operator's `node.advanced.updatePolicy` field accepts the **exact name** of a Sensor Update Policy from your Falcon tenant. The operator queries the Falcon API (`Sensor Update Policies: Read`) every 24 hours and uses that policy to determine which sensor version should be running. This means:

- **No manifest changes** are needed to roll a sensor update.
- **Version governance stays in the Falcon console** — the same place you manage all other endpoint update policies.
- **Different clusters can reference different policies** (e.g., staging uses `Auto - Latest`, production uses `Auto - N-1`).

## Step-by-Step: Create a Sensor Update Policy

1. In the Falcon console, go to **Host setup and management > Deploy > Sensor update policies**.
2. Click **Create policy**.
3. Enter a **Policy name** that matches exactly what you will put in `updatePolicy:` in your manifest.
   - Suggested naming convention: `k8s-<env>` — e.g., `k8s-prod`, `k8s-staging`, `k8s-dev`
4. Select **Linux** from the Platform dropdown.
5. Optionally enter a Description.
6. Click **Create policy**.
7. On the **Sensor settings** tab, select a sensor version:

| Version Setting | Behavior | Recommended For |
|---|---|---|
| `Auto - Latest` | Updates to the newest version on each scheduled release | Dev / test clusters |
| `Auto - N-1` | Updates to the second-newest version | Staging / pre-prod clusters |
| `Auto - N-2` | Updates to the third-newest version | Production clusters (most conservative) |
| `Auto - Early Adopter` | Updates to early adopter builds when available | CrowdStrike early adopter program participants |
| Fixed version | Pins to a specific build number (e.g., `7.18.17706`) | Environments requiring explicit change control |

8. Enable the policy (toggle it on).
9. Note the **exact policy name** — it is case-sensitive when referenced in the operator manifest.

## Recommended Policy Strategy

```
┌─────────────────────────────────────────────────────────────┐
│                   Falcon Console Policies                    │
├──────────────────┬──────────────────┬───────────────────────┤
│  Policy Name     │  Version Setting │  Clusters             │
├──────────────────┼──────────────────┼───────────────────────┤
│  k8s-dev         │  Auto - Latest   │  Development          │
│  k8s-staging     │  Auto - N-1      │  Staging / pre-prod   │
│  k8s-prod        │  Auto - N-2      │  Production           │
│  k8s-lts         │  Fixed (LTS)     │  Compliance-sensitive │
└──────────────────┴──────────────────┴───────────────────────┘
```

In each cluster's `falcondeployment.yaml`, set `updatePolicy` to the appropriate policy name:

```yaml
# Production cluster
node:
  advanced:
    autoUpdate: normal
    updatePolicy: "k8s-prod"   # Auto - N-2 in the Falcon console
```

```yaml
# Staging cluster
node:
  advanced:
    autoUpdate: normal
    updatePolicy: "k8s-staging"  # Auto - N-1 in the Falcon console
```

## Verifying the Policy is Being Applied

After deploying, confirm the operator is reading the policy correctly:

```bash
# Check the advanced config on the FalconNodeSensor resource
kubectl get falconnodesensor -n falcon-system -o yaml | grep -A 4 advanced

# Check operator logs for policy lookup activity
kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager \
  | grep -i "policy\|version\|update"

# Check current deployed sensor version
kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'
```

## Important Notes

- The `Sensor Update Policies: Read` API scope **must** be present on the API client used by the operator. Without it, `autoUpdate` and `updatePolicy` are silently ignored and the sensor version will not change automatically.
- If the named policy does not exist in the Falcon console, the operator will log an error on the next reconcile cycle.
- Policy names are **case-sensitive**.
- For DaemonSet sensor versions **7.33 and earlier**: if the existing sensor has **Uninstall and maintenance protection** enabled on its update policy, upgrades will be blocked. Move the sensor to a policy with that setting disabled before upgrading.

## Auto-Update Frequency

The operator checks for new sensor releases every **24 hours** by default. This interval can be changed by setting the `--sensor-auto-update-interval` flag on the operator deployment, but CrowdStrike recommends leaving it at the default to avoid API throttling.
