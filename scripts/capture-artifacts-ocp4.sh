#!/bin/bash -x
echo "Capturing the System Information"
if [ -d ${WORKSPACE}/deploy ];then
    cd ${WORKSPACE}/deploy
else
    exit 1
fi
# Capturing Terraform template
if [ ! -f ${WORKSPACE}/deploy/.${TARGET}.tfvars ]; then
    echo "${WORKSPACE}/deploy/.${TARGET}.tfvars not found!"
    exit 1
else
    cp ${WORKSPACE}/deploy/.${TARGET}.tfvars ${TARGET}.tfvars
    sed -i "s|password.*=.*$|password = ************|g" ${TARGET}.tfvars
    sed -i "s|user_name.*=.*$|user_name = ************|g" ${TARGET}.tfvars
    sed -i "s|auth_url.*=.*$|auth_url = ************|g" ${TARGET}.tfvars
    sed -i "s|rhel_subscription_password.*=.*$|rhel_subscription_password = ************|g" ${TARGET}.tfvars
    sed -i "s|rhel_subscription_username.*=.*$|rhel_subscription_username = ************|g" ${TARGET}.tfvars
    sed -i "s|github_token.*=.*$|github_token = ************|g" ${TARGET}.tfvars
    sed -i "s|github_username.*=.*$|github_username = ************|g" ${TARGET}.tfvars
    sed -i "s|ibmcloud_api_key.*=.*$|ibmcloud_api_key = ************|g" ${TARGET}.tfvars
    sed -i "s|proxy.*=.*$|proxy = ************|g" ${TARGET}.tfvars
    cp ${TARGET}.tfvars vars.tfvars
    tar -czvf ${WORKSPACE}/deploy/logs.tar.gz ${WORKSPACE}/deploy/.${TARGET}/logs
fi
if [ ! -z "${BASTION_IP}" ]; then
    ssh -q -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP} exit
    rc=$?
    if [ $? -eq 0 ] ; then
        ssh -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP} tar -czf ~/e2e_tests_results/conformance-parallel-out.txt.tar.gz ~/e2e_tests_results > /dev/null 2>&1
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/e2e_tests_results/conformance-parallel-out.txt.tar.gz .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/e2e_tests_results/summary.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/e2e_tests_results/e2e-upgrade-summary.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/scale_test_results/time_taken .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/e2e_tests_results/conformance-parallel/junit_e2e_*.xml junit_e2e.xml
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/e2e_tests_results/conformance-parallel-upgrade/junit_e2e_*.xml junit_e2e_upgrade.xml
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/cron.log .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/verification.log .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/time_taken_deployments .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/time_taken_namespaces .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/stability-check.log .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/result/success.txt ./successful_tests_cni_ovn_validation.txt
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/result/failed.txt ./failed_tests_cni_ovn_validation.txt
        cp ${WORKSPACE}/logs-ocs-ci/${ODF_VERSION}/test_results_tier${TIER_TEST}_1.xml ${WORKSPACE}/
        cp ${WORKSPACE}/logs-ocs-ci/${ODF_VERSION}/results.html ${WORKSPACE}/
        cp ${WORKSPACE}/logs-ocs-ci/${ODF_VERSION}/test_results.xml ${WORKSPACE}
        tar -czf ${WORKSPACE}/results.tar.gz ${WORKSPACE}/ocs-upi-kvm/scripts/tier*.log ${WORKSPACE}/logs-ocs-ci ${WORKSPACE}/ocs-upi-kvm/scripts/deploy-ocs-ci.log ${WORKSPACE}/ocs-upi-kvm/scripts/setup-ocs-ci.log ${WORKSPACE}/ocs-upi-kvm/scripts/helper/vault-setup.log ${WORKSPACE}/ocs-upi-kvm/scripts/helper/kustomize.log ${WORKSPACE}/odf-commands.txt  ${WORKSPACE}/ocs-upi-kvm/scripts/upgrade-ocs-ci.log ${WORKSPACE}/odf-full-build.txt ${WORKSPACE}/logs-ocs-ci/${ODF_VERSION}/test_results_tier*.xml ${WORKSPACE}/ocs-upi-kvm/scripts/tier${TIER_TEST}.log --ignore-failed-read > /dev/null 2>&1
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/cro_e2e_output.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/kdump.tar.gz .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:/tmp/compliance/e2e-*.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:/tmp/croo/e2e-test-result/croo_e2e_output_*.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:/tmp/fio/fio-e2e-*.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:/tmp/metallb/e2e-metallb-*-logs.txt .
        scp -i id_rsa -o StrictHostKeyChecking=no root@${BASTION_IP}:~/cron_quay.log .
        # Restoring resolv.conf
        cp -rf /etc/resolv.conf.tmp /etc/resolv.conf || true
    else
        echo 'Unable to access Bastion. You may delete the VMs manually'
    fi
else
    echo 'Unable to access Bastion. You may delete the VMs manually'
fi
