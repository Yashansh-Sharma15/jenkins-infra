def call(Map config = [:]) {
    /**
     * Posts test summary, cluster health check, and screenshots as attachments & comments to Jira.
     * Parameters:
     *   issue: e.g. "POCPQE-2563" (required)
     *   jobType: "direct-deploy" | "current-upgrade" | "next-upgrade" (required)
     *   release: e.g. "4.19.50" (required)
     *   clusterDetails: e.g. "${WORKSPACE}/deploy/vars.tfvars"
     *   healthLog: e.g. "${WORKSPACE}/deploy/cluster-health.log"
     *   e2eLog: e.g. "${WORKSPACE}/deploy/summary.txt"
     *   screenshotsDir: e.g. "${WORKSPACE}/deploy/ui-screenshots"
     *   extraAttachments: list of file paths (optional)
     */
    def issue = config.issue ?: env.JIRA_TICKET_ID
    if (!issue?.trim()) {
        echo "No Jira Ticket ID provided (JIRA_TICKET_ID is empty). Skipping Jira report post."
        return
    }

    def jobType = config.jobType ?: "direct-deploy"
    def release = config.release ?: env.OCP_RELEASE ?: ""
    def clusterDetails = config.clusterDetails ?: "${WORKSPACE}/deploy/vars.tfvars"
    def healthLog = config.healthLog ?: "${WORKSPACE}/deploy/cluster-health.log"
    def e2eLog = config.e2eLog ?: "${WORKSPACE}/deploy/summary.txt"
    def screenshotsDir = config.screenshotsDir ?: "${WORKSPACE}/deploy/ui-screenshots"

    try {
        withCredentials([string(credentialsId: 'JIRA_API_TOKEN', variable: 'JIRA_API_TOKEN')]) {
            def scriptPath = "${WORKSPACE}/jenkins-infra/scripts/jira-helper.py"
            if (!fileExists(scriptPath)) {
                scriptPath = "${WORKSPACE}/scripts/jira-helper.py"
            }

            def cmd = "python3 ${scriptPath} post-report " +
                      "--issue \"${issue}\" " +
                      "--job-type \"${jobType}\" " +
                      "--release \"${release}\" "

            if (fileExists(clusterDetails)) {
                cmd += "--cluster-details \"${clusterDetails}\" "
            }
            if (fileExists(healthLog)) {
                cmd += "--health-log \"${healthLog}\" "
            }
            if (fileExists(e2eLog)) {
                cmd += "--e2e-log \"${e2eLog}\" "
            }
            if (fileExists(screenshotsDir)) {
                cmd += "--screenshots-dir \"${screenshotsDir}\" "
            }

            echo "Posting summary report and attachments to Jira Issue: ${issue}..."
            sh """
                export JIRA_BASE_URL="https://jsw.ibm.com"
                chmod +x ${scriptPath} || true
                ${cmd} || true
            """
            echo "Jira update completed."
        }
    } catch (err) {
        echo "WARNING: Failed to post report to Jira: ${err.toString()}"
    }
}
