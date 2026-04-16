# Model 3: GitOps (ArgoCD or Flux)

The git repo is the desired state. A GitOps controller watches this repo and continuously reconciles each EKS cluster to match. Drift — including manual `kubectl` edits — is automatically corrected.

**Best for:** Teams already running ArgoCD or Flux, multi-cluster environments, audit/compliance requirements.

---

## Directory layout

```
deploy/gitops/
├── kustomize/
│   ├── base/                          # Shared FalconDeployment — updatePolicy unset
│   └── overlays/
│       ├── dev/                       # updatePolicy: k8s-dev   (Auto - Latest)
│       ├── staging/                   # updatePolicy: k8s-staging (Auto - N-1)
│       └── prod/                      # updatePolicy: k8s-prod   (Auto - N-2)
├── argocd/
│   └── application.yaml              # ArgoCD Application manifests (one per env)
├── flux/
│   └── kustomization.yaml            # Flux GitRepository + Kustomization resources
└── external-secrets/
    └── externalsecret.yaml           # Replaces manually-created Kubernetes secret
```

---

## How two reconcilers coexist

The critical design point: **the Falcon Operator and your GitOps controller both reconcile the same FalconDeployment resource**. They must not fight each other.

```
GitOps controller  →  enforces spec fields defined in git
Falcon Operator    →  manages status + updates node.image after auto-update
```

The GitOps controller must be told to **ignore operator-owned fields** — primarily `/status` on all Falcon CRDs, and `/spec/node/image` on FalconNodeSensor (which the operator updates after rolling a new sensor version). This is handled in the ArgoCD `ignoreDifferences` block and noted in the Flux Kustomization comments.

The `updatePolicy` field stays static in git. The Falcon Operator reads it, resolves the current sensor version from the Falcon console, and manages the rest — no git commit needed to roll a sensor update.

---

## Setup: Secrets (do this first)

In the GitOps model, the `falcon-secrets` Kubernetes secret is created by **External Secrets Operator** syncing from AWS Secrets Manager — not by a manual `kubectl create secret` command.

### 1. Store credentials in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name "/falcon/eks/<cluster-name>/credentials" \
  --region <region> \
  --secret-string '{
    "falcon-client-id": "<your-client-id>",
    "falcon-client-secret": "<your-client-secret>",
    "falcon-cid": "<your-cid-with-checksum>"
  }'
```

### 2. Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

### 3. Apply the ExternalSecret

Update the secret name and region in `external-secrets/externalsecret.yaml`, then apply:

```bash
kubectl apply -f deploy/gitops/external-secrets/externalsecret.yaml
```

Verify the Kubernetes secret was created:

```bash
kubectl get secret falcon-secrets -n falcon-operator
```

---

## Setup: Falcon Operator

Install the operator before the GitOps controller starts syncing the FalconDeployment (the operator must exist to handle the CRD):

```bash
OPERATOR_VERSION="v1.7.0"
kubectl apply -f https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml
kubectl wait --for=condition=Available deployment/falcon-operator-controller-manager \
  -n falcon-operator --timeout=120s
```

---

## Setup: ArgoCD

### 1. Install ArgoCD (if not already running)

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 2. Update `argocd/application.yaml`

Set the correct `destination.server` URL for each cluster. For the current cluster:
```yaml
destination:
  server: https://kubernetes.default.svc
```

For a remote cluster, use its API server URL (register it with `argocd cluster add` first).

### 3. Apply the Application manifests

```bash
kubectl apply -f deploy/gitops/argocd/application.yaml
```

ArgoCD will immediately begin syncing the appropriate overlay to each cluster.

---

## Setup: Flux

### 1. Bootstrap Flux (if not already running)

```bash
flux bootstrap github \
  --owner=jmckenzie-cs \
  --repository=falcon-operator-sensor-deployment \
  --branch=main \
  --path=deploy/gitops/flux \
  --personal
```

### 2. Apply the Kustomization

Update the overlay `path` in `flux/kustomization.yaml` for this cluster's environment, then:

```bash
kubectl apply -f deploy/gitops/flux/kustomization.yaml
```

Flux will reconcile on the configured interval (default: 10 minutes).

---

## Verifying GitOps sync

**ArgoCD:**
```bash
argocd app get falcon-sensor-prod
argocd app sync falcon-sensor-prod   # trigger immediate sync
```

**Flux:**
```bash
flux get kustomizations
flux reconcile kustomization falcon-sensor-prod   # trigger immediate reconcile
```

**Either:**
```bash
# Confirm sensor is running with correct update policy
kubectl get falconnodesensor -n falcon-system -o yaml | grep -A 3 advanced
kubectl get falconnodesensor -A -o=jsonpath='{.items[].status.version}'
```

---

## Creating a new Sensor Update Policy

1. In the Falcon console, create the policy (see [`update-policies/sensor-update-policy-guide.md`](../../update-policies/sensor-update-policy-guide.md)).
2. Add a new overlay directory under `deploy/gitops/kustomize/overlays/<env>/`.
3. Set `updatePolicy` in `patch-update-policy.yaml` to the new policy name.
4. Add an ArgoCD Application or Flux Kustomization pointing at the new overlay.
5. Merge to `main` — the GitOps controller deploys automatically.
