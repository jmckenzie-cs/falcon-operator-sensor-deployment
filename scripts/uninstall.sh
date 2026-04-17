#!/usr/bin/env bash
# uninstall.sh — Remove Falcon Operator and all deployed Falcon components from an EKS cluster
#
# Usage:
#   export AWS_REGION="us-east-1"
#   export EKS_CLUSTER_NAME="my-cluster"
#   export OPERATOR_VERSION="v1.7.0"   # must match the version that was installed
#   ./scripts/uninstall.sh
#
# What this script removes (in order):
#   1. FalconDeployment — triggers the Operator to clean up all child resources
#   2. falcon-secrets Kubernetes secret
#   3. Falcon Operator (controller, CRDs, RBAC)
#   4. falcon-operator namespace
#
# IMPORTANT — GitOps users:
#   If ArgoCD or Flux is managing this deployment, remove or suspend the
#   Application/Kustomization first. Otherwise the GitOps controller will
#   immediately redeploy after this script removes everything.

set -euo pipefail

: "${AWS_REGION:?AWS_REGION must be set}"
: "${EKS_CLUSTER_NAME:?EKS_CLUSTER_NAME must be set}"
: "${OPERATOR_VERSION:=v1.7.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Falcon Operator Uninstaller — Amazon EKS"
echo "    Cluster          : ${EKS_CLUSTER_NAME} (${AWS_REGION})"
echo "    Operator version : ${OPERATOR_VERSION}"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Configure kubeconfig
# ---------------------------------------------------------------------------
echo "==> Step 0: Configuring kubeconfig..."
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER_NAME}"
echo "    kubeconfig configured."

# ---------------------------------------------------------------------------
# Step 1: Delete FalconDeployment
# Deleting the FalconDeployment CR causes the Operator to tear down all child
# resources (FalconNodeSensor DaemonSet, FalconAdmission, FalconImageAnalyzer)
# via its finalizers before the CR itself is removed.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 1: Deleting FalconDeployment..."
if kubectl get falcondeployment falcon-deployment &>/dev/null; then
  kubectl delete falcondeployment falcon-deployment --timeout=120s
  echo "    FalconDeployment deleted."
else
  echo "    FalconDeployment not found, skipping."
fi

# Wait for child namespaces to be cleaned up by the Operator
echo "    Waiting for Falcon component namespaces to be removed..."
for ns in falcon-system falcon-kac falcon-iar; do
  if kubectl get namespace "${ns}" &>/dev/null; then
    echo "    Waiting for namespace ${ns} to be removed..."
    kubectl wait --for=delete namespace/"${ns}" --timeout=120s 2>/dev/null || \
      echo "    WARNING: namespace ${ns} did not delete within timeout — continuing"
  fi
done

# ---------------------------------------------------------------------------
# Step 2: Delete the credentials secret
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 2: Deleting falcon-secrets..."
if kubectl get secret falcon-secrets -n falcon-operator &>/dev/null; then
  kubectl delete secret falcon-secrets -n falcon-operator
  echo "    Secret deleted."
else
  echo "    Secret not found, skipping."
fi

# ---------------------------------------------------------------------------
# Step 3: Uninstall the Falcon Operator
# Uses the same manifest URL as install.sh so CRDs, RBAC, and the controller
# deployment are all removed.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 3: Uninstalling Falcon Operator ${OPERATOR_VERSION}..."
OPERATOR_URL="https://github.com/crowdstrike/falcon-operator/releases/download/${OPERATOR_VERSION}/falcon-operator.yaml"
kubectl delete -f "${OPERATOR_URL}" --ignore-not-found=true
echo "    Operator resources deleted."

# ---------------------------------------------------------------------------
# Step 4: Delete the falcon-operator namespace
# The namespace may already be gone after Step 3 depending on what the
# operator manifest includes; --ignore-not-found handles that cleanly.
# ---------------------------------------------------------------------------
echo ""
echo "==> Step 4: Deleting falcon-operator namespace..."
kubectl delete namespace falcon-operator --ignore-not-found=true --timeout=60s
echo "    Namespace deleted (or was already absent)."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
echo "  Falcon Operator uninstall complete."
echo ""
echo "  Verify nothing was left behind:"
echo "    kubectl get ns | grep falcon"
echo "    kubectl get falcondeployment,falconnodesensors,falconadmission,falconimageanalyzer -A 2>/dev/null"
echo "=================================================="
