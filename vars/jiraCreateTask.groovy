def call(Map config = [:]) {
    /**
     * Creates a Jira task under project (default: POCPQE) linked to Epic (default: POCPQE-5)
     * Parameters:
     *   release: e.g. "4.19.50"
     *   currentStable: e.g. "4.19.49"
     *   nextStable: e.g. "4.20.41"
     *   project: e.g. "POCPQE" (optional, default: POCPQE)
     *   epic: e.g. "POCPQE-5" (optional, default: POCPQE-5)
     * Returns:
     *   Jira Ticket ID (e.g. "POCPQE-2563") or empty string on failure
     */
    def release = config.release ?: ""
    def currentStable = config.currentStable ?: ""
    def nextStable = config.nextStable ?: ""
    def project = config.project ?: "POCPQE"
    def epic = config.epic ?: "POCPQE-2576"
    def jiraTicketId = ""

    if (!release) {
        echo "No release version specified for Jira ticket creation. Skipping."
        return ""
    }

    try {
        withCredentials([string(credentialsId: 'JIRA_API_TOKEN', variable: 'JIRA_API_TOKEN')]) {
            def scriptPath = "${WORKSPACE}/jenkins-infra/scripts/jira-helper.py"
            if (!fileExists(scriptPath)) {
                scriptPath = "${WORKSPACE}/scripts/jira-helper.py"
            }

            def cmd = "python3 ${scriptPath} create-task " +
                      "--project \"${project}\" " +
                      "--epic \"${epic}\" " +
                      "--release \"${release}\" " +
                      "--current-stable \"${currentStable}\" " +
                      "--next-stable \"${nextStable}\" " +
                      "--output-file \"${WORKSPACE}/jira_ticket_id.txt\""

            sh """
                export JIRA_BASE_URL="https://jsw.ibm.com"
                chmod +x ${scriptPath} || true
                ${cmd} || true
            """

            if (fileExists("${WORKSPACE}/jira_ticket_id.txt")) {
                jiraTicketId = readFile("${WORKSPACE}/jira_ticket_id.txt").trim()
                echo "Successfully created Jira Ticket: ${jiraTicketId}"
            }
        }
    } catch (err) {
        echo "WARNING: Failed to create Jira ticket: ${err.toString()}"
    }

    return jiraTicketId
}
