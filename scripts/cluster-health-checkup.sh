#!/bin/bash
# cron_cluster_health.sh
# Captures general OpenShift cluster health and version information.

set -uo pipefail

export TZ='Asia/Kolkata'

SEPARATOR="================================================================"

section() {
    echo ""
    echo "$SEPARATOR"
    echo "  $1"
    echo "$SEPARATOR"
    echo ""
}

section "oc version"
oc version

section "kubectl version"
kubectl version

section "oc get nodes"
oc get nodes

section "oc adm top nodes"
oc adm top nodes

section "oc get clusteroperators"
oc get co

section "Pods not Running or Completed"
oc get pods -A | grep -v "Running\|Completed" || echo "All pods are Running or Completed"

section "Cluster Version History"
oc get clusterversion -o json | jq '.items[0].status.history'

section "Bastion OS Release"
if [ -n "${BASTION_IP:-}" ] && [ -f "${WORKSPACE}/deploy/id_rsa" ]; then
    ssh -o StrictHostKeyChecking=no \
        -i ${WORKSPACE}/deploy/id_rsa \
        root@${BASTION_IP} \
        "cat /etc/os-release" 2>/dev/null || cat /etc/os-release
else
    cat /etc/os-release
fi

section "Master-0 RHCOS Release"
oc debug node/master-0 -- chroot /host cat /etc/os-release

section "Worker-0 RHCOS Release"
oc debug node/worker-0 -- chroot /host cat /etc/os-release

section "E2E Test Summary"

echo ""
echo "Directory:"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "ls -lh /root/e2e_tests_results/" 2>/dev/null \
    || echo "e2e_tests_results not found on bastion"

section "summary.txt"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "cat /root/e2e_tests_results/summary.txt" 2>/dev/null \
    || echo "summary.txt not found on bastion"

section "failed-e2e-results.txt"
ssh -o StrictHostKeyChecking=no \
    -i ${WORKSPACE}/deploy/id_rsa \
    root@${BASTION_IP} \
    "cat /root/e2e_tests_results/failed-e2e-results.txt" 2>/dev/null \
    || echo "failed-e2e-results.txt not found on bastion"


echo ""
echo "$SEPARATOR"
echo "  Collection complete"
echo "$SEPARATOR"
echo ""