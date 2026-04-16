# Troubleshooting

## Quick Diagnostics

```bash
# Operator health
kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager

# All Falcon resources at a glance
kubectl get falcondeployment,falconnodesensors,falconadmission,falconimageanalyzer -A

# DaemonSet status
kubectl get daemonsets.apps -n falcon-system

# Currently deployed sensor version
kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'

# Auto-update config
kubectl get falconnodesensor -n falcon-system -o yaml | grep -A 4 advanced

# Secret exists
kubectl get secret falcon-secrets -n falcon-operator
```

---

## Common Issues

### Sensors not deploying — ImagePullBackOff

**Symptom:** DaemonSet pods stuck in `ImagePullBackOff`.

**Cause:** API credentials are missing or have insufficient scopes.

**Resolution:**
1. Verify the secret exists: `kubectl get secret falcon-secrets -n falcon-operator`
2. In the Falcon console, check the API client has **Falcon Images Download: Read** and **Sensor Download: Read** scopes.
3. Re-create the secret if needed (see `sensors/node-sensor/secret.yaml`).

---

### Auto-update not working

**Symptom:** Sensor version does not change even though the Falcon policy was updated.

**Cause:** Missing `Sensor Update Policies: Read` API scope, or `autoUpdate` is not configured.

**Resolution:**
1. Verify API scope in the Falcon console under **API clients and keys**.
2. Check the FalconNodeSensor advanced config:
   ```bash
   kubectl get falconnodesensor -n falcon-system -o yaml | grep -A 4 advanced
   ```
3. Check operator logs for update activity:
   ```bash
   kubectl -n falcon-operator logs deploy/falcon-operator-controller-manager -c manager \
     | grep -i "update\|version\|policy"
   ```
4. Verify the policy name matches exactly (case-sensitive):
   ```bash
   kubectl get falconnodesensor -n falcon-system \
     -o jsonpath='{.items[0].spec.node.advanced.updatePolicy}'
   ```

---

### Update blocked on sensor version 7.33 or earlier

**Symptom:** Operator logs show the DaemonSet update is blocked.

**Cause:** The active Sensor Update Policy has **Uninstall and maintenance protection** enabled.

**Resolution:**
1. In the Falcon console, create a temporary policy with **Uninstall and maintenance protection** disabled and **Sensor version updates** set to off.
2. Move the affected Kubernetes host group to this temporary policy.
3. Trigger the upgrade via the operator.
4. Move the host group back to the production policy.

---

### Named policy not found

**Symptom:** Operator logs contain an error referencing the policy name.

**Cause:** The `updatePolicy` value in the manifest does not match any existing policy name in the Falcon console.

**Resolution:**
- Policy names are **case-sensitive**.
- Verify the exact policy name in the Falcon console under **Sensor update policies**.
- Update `node.advanced.updatePolicy` in the manifest and re-apply.

---

### FalconDeployment stuck in reconciling

**Symptom:** `kubectl get falcondeployment` shows the resource stuck.

**Resolution:**
```bash
# View full CRD details for status conditions
kubectl get falcondeployment -o yaml

# View operator logs
kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager
```

---

### Verify update check interval

```bash
kubectl get deployment falcon-operator -n falcon-operator -o yaml \
  | grep sensor-auto-update-interval
```

If no custom interval is configured, the default is **24 hours**.

---

### FalconNodeSensor not scheduling on all nodes

**Symptom:** `desiredNumberScheduled` > `numberReady` after a reasonable wait.

**Resolution:**
1. Check for tainted nodes:
   ```bash
   kubectl get nodes -o json | jq '.items[].spec.taints'
   ```
2. If tainted nodes need sensors, add appropriate tolerations in `falcondeployment.yaml`:
   ```yaml
   falconNodeSensor:
     node:
       tolerations:
         - key: "dedicated"
           operator: "Equal"
           value: "gpu"
           effect: "NoSchedule"
   ```
3. Re-apply the manifest.

---

## Useful kubectl Commands Reference

| Task | Command |
|---|---|
| Operator logs | `kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager` |
| FalconDeployment detail | `kubectl get falcondeployment -o yaml` |
| FalconNodeSensor detail | `kubectl get falconnodesensor -A -o yaml` |
| Sensor version | `kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'` |
| DaemonSet status | `kubectl get daemonsets.apps -n falcon-system` |
| KAC logs | `kubectl logs -n falcon-kac -l "crowdstrike.com/provider=crowdstrike"` |
| IAR logs | `kubectl logs -n falcon-iar -l "crowdstrike.com/provider=crowdstrike"` |
| Auto-update config | `kubectl get falconnodesensor -n falcon-system -o yaml \| grep -A 4 advanced` |
