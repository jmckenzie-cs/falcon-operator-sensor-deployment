#!/usr/bin/env bash
# verify.sh — Post-install verification for Falcon Operator deployment
#
# Usage:
#   ./scripts/verify.sh

set -euo pipefail

PASS="[PASS]"
WARN="[WARN]"
FAIL="[FAIL]"
INFO="[INFO]"

errors=0

echo "======================================================"
echo "  Falcon Operator Deployment Verification"
echo "======================================================"
echo ""

# ---------------------------------------------------------------------------
# Operator pod
# ---------------------------------------------------------------------------
echo "-- Operator Controller --"
if kubectl get deployment falcon-operator-controller-manager -n falcon-operator &>/dev/null; then
  READY=$(kubectl get deployment falcon-operator-controller-manager \
    -n falcon-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${READY}" -ge 1 ]]; then
    echo "${PASS} Falcon Operator controller is running (${READY} ready replicas)"
  else
    echo "${FAIL} Falcon Operator controller is NOT ready"
    ((errors++))
  fi
else
  echo "${FAIL} Falcon Operator deployment not found. Is the operator installed?"
  ((errors++))
fi
echo ""

# ---------------------------------------------------------------------------
# FalconDeployment CRD
# ---------------------------------------------------------------------------
echo "-- FalconDeployment --"
if kubectl get falcondeployment &>/dev/null 2>&1; then
  echo "${PASS} FalconDeployment CRD exists"
  FD_STATUS=$(kubectl get falcondeployment -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  if [[ -n "${FD_STATUS}" ]]; then
    echo "${INFO} FalconDeployment resources: ${FD_STATUS}"
  fi
else
  echo "${WARN} No FalconDeployment resources found (may still be creating)"
fi
echo ""

# ---------------------------------------------------------------------------
# FalconNodeSensor
# ---------------------------------------------------------------------------
echo "-- FalconNodeSensor (DaemonSet) --"
if kubectl get falconnodesensors -A &>/dev/null 2>&1; then
  SENSOR_VERSION=$(kubectl get falconnodesensor -A \
    -o=jsonpath='{.items[0].status.version}' 2>/dev/null || echo "unknown")
  echo "${PASS} FalconNodeSensor resource exists"
  echo "${INFO} Deployed sensor version: ${SENSOR_VERSION}"

  DS_DESIRED=$(kubectl get daemonsets.apps -n falcon-system \
    -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
  DS_READY=$(kubectl get daemonsets.apps -n falcon-system \
    -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo "0")

  if [[ "${DS_DESIRED}" -gt 0 && "${DS_DESIRED}" == "${DS_READY}" ]]; then
    echo "${PASS} DaemonSet: ${DS_READY}/${DS_DESIRED} nodes ready"
  else
    echo "${WARN} DaemonSet: ${DS_READY}/${DS_DESIRED} nodes ready (may still be rolling out)"
  fi

  # Check autoUpdate config
  AUTO_UPDATE=$(kubectl get falconnodesensor -n falcon-system \
    -o jsonpath='{.items[0].spec.node.advanced.autoUpdate}' 2>/dev/null || echo "not set")
  UPDATE_POLICY=$(kubectl get falconnodesensor -n falcon-system \
    -o jsonpath='{.items[0].spec.node.advanced.updatePolicy}' 2>/dev/null || echo "not set")
  echo "${INFO} autoUpdate: ${AUTO_UPDATE}"
  echo "${INFO} updatePolicy: ${UPDATE_POLICY}"
else
  echo "${WARN} FalconNodeSensor not found (may still be creating)"
fi
echo ""

# ---------------------------------------------------------------------------
# FalconAdmission (KAC)
# ---------------------------------------------------------------------------
echo "-- FalconAdmission (KAC) --"
if kubectl get falconadmission &>/dev/null 2>&1; then
  KAC_VERSION=$(kubectl get falconadmission \
    -o=jsonpath='{.items[0].status.version}' 2>/dev/null || echo "unknown")
  echo "${PASS} FalconAdmission resource exists (version: ${KAC_VERSION})"
else
  echo "${WARN} FalconAdmission not found"
fi
echo ""

# ---------------------------------------------------------------------------
# FalconImageAnalyzer (IAR)
# ---------------------------------------------------------------------------
echo "-- FalconImageAnalyzer (IAR) --"
if kubectl get falconimageanalyzer &>/dev/null 2>&1; then
  IAR_VERSION=$(kubectl get falconimageanalyzer \
    -o=jsonpath='{.items[0].status.version}' 2>/dev/null || echo "unknown")
  echo "${PASS} FalconImageAnalyzer resource exists (version: ${IAR_VERSION})"
else
  echo "${WARN} FalconImageAnalyzer not found"
fi
echo ""

# ---------------------------------------------------------------------------
# Credentials check
# ---------------------------------------------------------------------------
echo "-- Credentials Secret --"
if kubectl get secret falcon-secrets -n falcon-operator &>/dev/null 2>&1; then
  echo "${PASS} Secret 'falcon-secrets' exists in namespace 'falcon-operator'"
else
  echo "${FAIL} Secret 'falcon-secrets' not found in namespace 'falcon-operator'"
  ((errors++))
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "======================================================"
if [[ "${errors}" -eq 0 ]]; then
  echo "  Result: All checks passed."
else
  echo "  Result: ${errors} check(s) failed. Review output above."
fi
echo ""
echo "  Useful next commands:"
echo "    kubectl get falcondeployment -o wide"
echo "    kubectl get daemonsets.apps -n falcon-system"
echo "    kubectl -n falcon-operator logs -f deploy/falcon-operator-controller-manager -c manager"
echo "======================================================"

exit "${errors}"
