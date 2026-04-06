#!/bin/bash
set -euo pipefail

echo "Creating quay_vars.yaml"

rm -rf ~/.ansible
ansible all -m setup -a 'gather_subset=!all'

echo "Processing pull secret..."

if [ -n "${PULL_SECRET_INPUT:-}" ]; then

  echo "Writing new pull secret to file"
  printf '%s' "${PULL_SECRET_INPUT}" > /tmp/new_pull_secret.json

  echo "Validating JSON..."
  jq empty /tmp/new_pull_secret.json || {
    echo "Invalid pull secret JSON"
    exit 1
  }

  echo "Fetching existing cluster pull secret"

  oc get secret/pull-secret -n openshift-config \
    -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/existing_pull_secret.json

  if [ ! -s /tmp/existing_pull_secret.json ]; then
    echo "ERROR: Existing pull secret is empty!"
    exit 1
  fi

  echo "Merging pull secrets"
  jq -s '
  {
    auths: (.[0].auths + .[1].auths)
  }
  ' /tmp/existing_pull_secret.json /tmp/new_pull_secret.json > /tmp/merged_pull_secret.json

  echo "Applying merged pull secret"
  oc set data secret/pull-secret -n openshift-config \
    --from-file=.dockerconfigjson=/tmp/merged_pull_secret.json

  echo "Waiting for pull secret propagation..."
  sleep 60

else
  echo "No pull secret provided, skipping update"
fi

cd ${WORKSPACE}/ocp4-playbooks-extras

cp examples/ocp_quay_vars.yaml quay_vars.yaml

sed -i "s|quay_enabled:.*$|quay_enabled: true|g" quay_vars.yaml
sed -i "s|quay_registry_namespace:.*$|quay_registry_namespace: quay-registry|g" quay_vars.yaml
sed -i "s|quay_operator_channel:.*$|quay_operator_channel: ${QUAY_OPERATOR_CHANNEL}|g" quay_vars.yaml

if [ -n "${QUAY_CATALOGSOURCE_IMAGE}" ]; then
  echo "Using custom catalog source for QUAY"
  sed -i "s|quay_catalogsource_name:.*$|quay_catalogsource_name: quay-custom-catsrc|g" quay_vars.yaml
  sed -i "s|quay_catalogsource_image:.*$|quay_catalogsource_image: ${QUAY_CATALOGSOURCE_IMAGE}|g" quay_vars.yaml

else
  echo "Using default redhat-operators catalog"
  sed -i "s|quay_catalogsource_name:.*$|quay_catalogsource_name: redhat-operators|g" quay_vars.yaml
  sed -i "s|quay_catalogsource_image:.*$|quay_catalogsource_image: ''|g" quay_vars.yaml
fi

sed -i "s|quay_registry_hostname:.*$|quay_registry_hostname: quay-registry.$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}')|g" quay_vars.yaml
sed -i "s|cluster_upi:.*$|cluster_upi: true|g" quay_vars.yaml
sed -i "s|volume_path:.*$|volume_path: /dev/quay|g" quay_vars.yaml
sed -i "s|quay_enable_global_secret:.*$|quay_enable_global_secret: false|g" quay_vars.yaml
cat quay_vars.yaml

cp examples/inventory ./quay_inventory
sed -i "s|localhost|${BASTION_IP}|g" quay_inventory
sed -i 's/ansible_connection=local/ansible_connection=ssh/g' quay_inventory
sed -i "s|ssh|ssh ansible_ssh_private_key_file=${WORKSPACE}/deploy/id_rsa|g" quay_inventory

ansible-playbook -i quay_inventory -e @quay_vars.yaml playbooks/ocp-quay.yml
