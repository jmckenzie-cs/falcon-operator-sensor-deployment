# Uninstalling Falcon Operator and Components

This guide covers complete removal of the Falcon Operator and all deployed Falcon components from an EKS cluster.

## Before You Begin

**GitOps users (ArgoCD / Flux):** Suspend or delete the Application/Kustomization managing this deployment *before* running any removal steps. If you don't, the GitOps controller will detect drift and immediately redeploy everything after the script removes it.

**ArgoCD:**
```bash
argocd app delete falcon-sensor-prod   # or suspend: argocd app set falcon-sensor-prod --sync-policy none
```

**Flux:**
```bash
flux suspend kustomization falcon-sensor-prod
```

---

## Option A: Automated removal with `uninstall.sh`

```bash
export AWS_REGION="us-east-1"
export EKS_CLUSTER_NAME="my-cluster"
export OPERATOR_VERSION="v1.7.0"   # must match the version that was installed

bash scripts/uninstall.sh
```

The script removes everything in the correct order and waits for each step to complete before proceeding.

---

## Option B: Manual steps

> [!WARNING]
> **Order matters.** The Falcon Operator must be running when the FalconDeployment is deleted so it can run its finalizers and clean up child resources. **Deleting the Operator first orphans the DaemonSet and component namespaces.**

### 1. Delete the FalconDeployment

```bash
kubectl delete falcondeployment falcon-deployment --timeout=120s
```

The Operator will remove the FalconNodeSensor DaemonSet, FalconAdmission, and FalconImageAnalyzer resources. Wait for their namespaces to disappear:

```bash
kubectl get ns | grep falcon
```

Expected: only `falcon-operator` remains.

### 2. Delete the credentials secret

```bash
kubectl delete secret falcon-secrets -n falcon-operator
```

### 3. Uninstall the Operator

Use the same manifest URL and version that was used to install it:

```bash
OPERATOR_VERSION="v1.7.0"
kubectl delete -f "https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml" \
  --ignore-not-found=true
```

This removes the CRDs, RBAC, and the controller deployment.

### 4. Delete the falcon-operator namespace

```bash
kubectl delete namespace falcon-operator --ignore-not-found=true
```

---

## Verify complete removal

```bash
# No falcon namespaces should remain
kubectl get ns | grep falcon

# No Falcon CRD instances should remain (expect "No resources found" or "error: the server doesn't have a resource type")
kubectl get falcondeployment,falconnodesensors,falconadmission,falconimageanalyzer -A 2>/dev/null
```

---

## Partial removal — components only, keep the Operator

If you want to remove the sensors but leave the Operator in place (e.g., to redeploy with different settings):

```bash
# Remove only the FalconDeployment — Operator stays running
kubectl delete falcondeployment falcon-deployment --timeout=120s
```

Re-deploy at any time by re-running `install.sh` or re-applying the manifest.
