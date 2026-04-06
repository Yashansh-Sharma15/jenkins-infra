#!/bin/bash
# cron_quay.sh
# Captures Quay and OCP cluster state using oc commands directly in Jenkins.
# oc is already configured by setupKubeconfigOcp4() — no SSH or SCP needed.

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

section "oc get co"
oc get co

section "lsblk | grep 500 (worker-0)"
oc debug node/worker-0 -- chroot /host sh -c 'lsblk | grep 500'

section "lsblk | grep 500 (worker-1)"
oc debug node/worker-1 -- chroot /host sh -c 'lsblk | grep 500'

section "lsblk | grep 500 (worker-2)"
oc debug node/worker-2 -- chroot /host sh -c 'lsblk | grep 500'

section "oc get csv -n openshift-local-storage"
oc get csv -n openshift-local-storage

section "oc get sc"
oc get sc

section "oc get pv"
oc get pv

section "oc get localvolumediscovery auto-discover-devices -n openshift-local-storage"
oc get localvolumediscovery auto-discover-devices -n openshift-local-storage

section "oc get csv -n openshift-storage"
oc get csv -n openshift-storage

section "oc get pods -n openshift-storage"
oc get pods -n openshift-storage

section "oc get storagecluster -n openshift-storage"
oc get storagecluster -n openshift-storage

section "oc get storagesystem -n openshift-storage"
oc get storagesystem -n openshift-storage

section "oc get cephcluster -n openshift-storage"
oc get cephcluster -n openshift-storage

section "oc get pvc -n openshift-storage"
oc get pvc -n openshift-storage

section "oc get storagecluster ocs-storagecluster -n openshift-storage -o yaml"
oc get storagecluster ocs-storagecluster -n openshift-storage -o yaml

section "oc get csv -n quay-registry"
oc get csv -n quay-registry

section "oc get pods -n quay-registry"
oc get pods -n quay-registry

echo ""
echo "$SEPARATOR"
echo "  Collection complete"
echo "$SEPARATOR"
echo ""