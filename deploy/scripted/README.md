# Model 2: Scripted Imperative (install.sh)

Wraps `kubectl` in a repeatable shell script. Environment variables drive all runtime values — no manifest editing required. Runs once and exits; no ongoing enforcement.

**Best for:** Pipeline-triggered installs (e.g., Terraform provisions EKS → pipeline runs `install.sh`), multi-cluster installs with different env vars per cluster.

**Limitation:** Still imperative — no reconciliation after the script exits. If a resource is manually changed, it stays changed until the script is re-run.

---

## Script location

```
scripts/install.sh
scripts/verify.sh
```

## Required environment variables

| Variable | Description |
|---|---|
| `AWS_REGION` | EKS cluster AWS region (e.g., `us-east-1`) |
| `EKS_CLUSTER_NAME` | EKS cluster name |
| `FALCON_CLIENT_ID` | CrowdStrike API client ID |
| `FALCON_CLIENT_SECRET` | CrowdStrike API client secret |
| `FALCON_CID` | CrowdStrike CID with checksum |

## Optional environment variables

| Variable | Default | Description |
|---|---|---|
| `FALCON_CLOUD_REGION` | `autodiscover` | CrowdStrike cloud region (`us-1`, `us-2`, `eu-1`, `us-gov-1`) |
| `FALCON_UPDATE_POLICY` | `k8s-prod` | Exact name of the Falcon Sensor Update Policy |
| `OPERATOR_VERSION` | `v1.7.0` | Falcon Operator release version to install |

## Before you run

**`FALCON_UPDATE_POLICY` must match the exact name of a policy that already exists in your Falcon tenant.** The default value (`k8s-prod`) is a suggested name only — it will not be created automatically. If the policy doesn't exist, the operator will log an error on every reconcile cycle.

See [`update-policies/sensor-update-policy-guide.md`](../../update-policies/sensor-update-policy-guide.md) for steps to create the policy in the Falcon console before running this script.

## Usage

```bash
export AWS_REGION="us-east-1"
export EKS_CLUSTER_NAME="my-cluster"
export FALCON_CLIENT_ID="<your-client-id>"
export FALCON_CLIENT_SECRET="<your-client-secret>"
export FALCON_CID="<your-cid-with-checksum>"
export FALCON_UPDATE_POLICY="k8s-prod"

bash scripts/install.sh
```

## What the script does

1. Runs `aws eks update-kubeconfig` and verifies cluster-admin access
2. Installs the Falcon Operator and waits for it to be ready
3. Creates the `falcon-secrets` Kubernetes secret in the `falcon-operator` namespace
4. Applies `sensors/node-sensor/falcondeployment.yaml` with `FALCON_CLOUD_REGION` and `FALCON_UPDATE_POLICY` substituted in
5. Runs `scripts/verify.sh` to confirm all components are healthy

## Pipeline integration example

In a CI/CD pipeline that runs after Terraform provisions the EKS cluster:

```yaml
# Example: GitHub Actions step
- name: Deploy Falcon Sensor
  env:
    AWS_REGION: ${{ vars.AWS_REGION }}
    EKS_CLUSTER_NAME: ${{ vars.EKS_CLUSTER_NAME }}
    FALCON_CLIENT_ID: ${{ secrets.FALCON_CLIENT_ID }}
    FALCON_CLIENT_SECRET: ${{ secrets.FALCON_CLIENT_SECRET }}
    FALCON_CID: ${{ secrets.FALCON_CID }}
    FALCON_UPDATE_POLICY: ${{ vars.FALCON_UPDATE_POLICY }}
  run: bash scripts/install.sh
```

## Re-running the script

The script is idempotent — re-running it on an existing cluster will update the secret and re-apply the FalconDeployment manifest without disrupting running sensors.
