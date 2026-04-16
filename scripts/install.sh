#!/usr/bin/env bash
# install.sh — End-to-end Falcon Operator + FalconNodeSensor installation on Amazon EKS
#
# Usage:
#   export AWS_REGION="us-east-1"                      # EKS cluster region
#   export EKS_CLUSTER_NAME="my-cluster"               # EKS cluster name
#   export FALCON_CLIENT_ID="<your-client-id>"
#   export FALCON_CLIENT_SECRET="<your-client-secret>"
#   export FALCON_CID="<your-cid-with-checksum>"
#   export FALCON_CLOUD_REGION="autodiscover"          # or us-1, us-2, eu-1, us-gov-1
#   export FALCON_UPDATE_POLICY="k8s-prod"             # Name of your Sensor Update Policy
#   export OPERATOR_VERSION="v1.7.0"                   # Pin to a specific operator release
#   ./scripts/install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
: "${AWS_REGION:?AWS_REGION must be set}"
: "${EKS_CLUSTER_NAME:?EKS_CLUSTER_NAME must be set}"
: "${FALCON_CLIENT_ID:?FALCON_CLIENT_ID must be set}"
: "${FALCON_CLIENT_SECRET:?FALCON_CLIENT_SECRET must be set}"
: "${FALCON_CID:?FALCON_CID must be set}"
: "${FALCON_CLOUD_REGION:=autodiscover}"
: "${FALCON_UPDATE_POLICY:=k8s-prod}"
: "${OPERATOR_VERSION:=v1.7.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Falcon Operator Installer — Amazon EKS"
echo "    Cluster          : ${EKS_CLUSTER_NAME} (${AWS_REGION})"
echo "    Operator version : ${OPERATOR_VERSION}"
echo "    Cloud region     : ${FALCON_CLOUD_REGION}"
echo "    Update policy    : ${FALCON_UPDATE_POLICY}"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Configure kubeconfig for EKS
# ---------------------------------------------------------------------------
echo "==> Step 0: Configuring kubeconfig for EKS cluster..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"

# Confirm cluster access
if ! kubectl auth can-i '*' '*' --all-namespaces &>/dev/null; then
  echo "ERROR: kubectl does not have cluster-admin access. Check your IAM permissions."
  exit 1
fi
echo "    kubeconfig configured and cluster access verified."

# ---------------------------------------------------------------------------
# Step 1: Install the Falcon Operator
# ---------------------------------------------------------------------------
echo "==> Step 1: Installing Falcon Operator ${OPERATOR_VERSION}..."
kubectl apply -f "https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml"

echo "    Waiting for operator to become ready..."
kubectl wait --for=condition=Available \
  deployment/falcon-operator-controller-manager \
  -n falcon-operator \
  --timeout=120s

echo "    Operator is ready."

# ---------------------------------------------------------------------------
# Step 2: Create namespace and secret
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Creating namespace and credentials secret..."
kubectl apply -f "${REPO_ROOT}/sensors/node-sensor/namespace.yaml"

# Create (or update) the secret
kubectl create secret generic falcon-secrets \
  -n falcon-operator \
  --from-literal=falcon-client-id="${FALCON_CLIENT_ID}" \
  --from-literal=falcon-client-secret="${FALCON_CLIENT_SECRET}" \
  --from-literal=falcon-cid="${FALCON_CID}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "    Secret 'falcon-secrets' created/updated in namespace 'falcon-operator'."

# ---------------------------------------------------------------------------
# Step 3: Patch the FalconDeployment manifest with runtime values, then apply
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Applying FalconDeployment manifest..."

MANIFEST="${REPO_ROOT}/sensors/node-sensor/falcondeployment.yaml"

# Substitute cloud_region and updatePolicy into a temp file
TMPFILE="$(mktemp /tmp/falcondeployment.XXXXXX.yaml)"
trap 'rm -f "$TMPFILE"' EXIT

sed \
  -e "s|cloud_region: autodiscover|cloud_region: ${FALCON_CLOUD_REGION}|g" \
  -e "s|updatePolicy: \"k8s-prod\"|updatePolicy: \"${FALCON_UPDATE_POLICY}\"|g" \
  "${MANIFEST}" > "${TMPFILE}"

kubectl apply -f "${TMPFILE}"

echo "    FalconDeployment applied."

# ---------------------------------------------------------------------------
# Step 4: Verify
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Verification..."
echo "    (Allow up to 3 minutes for the DaemonSet to come up)"
echo ""

sleep 10

bash "${SCRIPT_DIR}/verify.sh"
