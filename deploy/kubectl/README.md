# Model 1: kubectl (Imperative)

Direct `kubectl` commands — no scripts, no GitOps controller. Apply manifests manually, changes take effect immediately.

**Best for:** Initial bootstrapping, one-off cluster installs, environments without CI/CD.

**Limitation:** No ongoing enforcement. Manual edits to resources persist uncorrected.

---

## Steps

### 0. Configure kubeconfig

```bash
aws eks update-kubeconfig --region <region> --name <cluster-name>
kubectl auth can-i '*' '*' --all-namespaces
```

### 1. Install the Falcon Operator

```bash
OPERATOR_VERSION="v1.7.0"
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml

kubectl wait --for=condition=Available \
  deployment/falcon-operator-controller-manager \
  -n falcon-operator --timeout=120s
```

### 2. Create the namespace and credentials secret

```bash
kubectl apply -f ../../sensors/node-sensor/namespace.yaml

kubectl create secret generic falcon-secrets \
  -n falcon-operator \
  --from-literal=falcon-client-id="${FALCON_CLIENT_ID}" \
  --from-literal=falcon-client-secret="${FALCON_CLIENT_SECRET}" \
  --from-literal=falcon-cid="${FALCON_CID}"
```

### 3. Create a Sensor Update Policy in the Falcon Console

See [`update-policies/sensor-update-policy-guide.md`](../../update-policies/sensor-update-policy-guide.md).
Note the exact policy name — it is case-sensitive.

### 4. Edit and apply the FalconDeployment manifest

Open `../../sensors/node-sensor/falcondeployment.yaml` and set:
- `falcon_api.cloud_region` — your CrowdStrike cloud region
- `node.advanced.updatePolicy` — exact name of your Sensor Update Policy

Then apply:

```bash
kubectl apply -f ../../sensors/node-sensor/falcondeployment.yaml
```

### 5. Verify

```bash
kubectl get falcondeployment -o wide
kubectl get falconnodesensors -A
kubectl get daemonsets.apps -n falcon-system
kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'
```

Or run the verify script:

```bash
bash ../../scripts/verify.sh
```

---

## Updating the sensor

Sensor versions are governed by the Falcon console Sensor Update Policy — no manifest changes needed. To change configuration (e.g., tolerations, proxy settings), edit and re-apply the manifest:

```bash
kubectl apply -f ../../sensors/node-sensor/falcondeployment.yaml
```

## Uninstalling

```bash
kubectl delete falcondeployment falcon-deployment
kubectl delete -f https://github.com/crowdstrike/falcon-operator/releases/download/v1.7.0/falcon-operator.yaml
```
