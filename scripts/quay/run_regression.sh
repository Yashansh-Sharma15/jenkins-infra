#!/bin/bash
# run_regression.sh
# Clones quay-tests repo and runs Cypress regression tests (API + Smoke).
# API spec is selected automatically based on QUAY_MINOR_VERSION:
#   3.15 and below → quay_api_testing_all.cy.js        (old UI)
#   3.16 and above → quay_api_testing_all_new_ui.cy.js (new UI)
# Smoke tests run for Quay 3.17 and below only.
#
# Required env vars (set by Jenkinsfile before calling this script):
#   QUAY_ENDPOINT         - e.g. quay-registry.apps.<cluster>.<domain>
#   OCP_ENDPOINT          - e.g. console-openshift-console.apps.<cluster>.<domain>:6443
#   KUBEADMIN_PASSWORD    - kubeadmin password for the OCP cluster
#   QUAY_VERSION          - e.g. 3.15, 3.18
#   QUAY_MINOR_VERSION    - e.g. 15, 18  (integer, for version comparisons)
#   GITHUB_USER           - GitHub username for cloning quay-tests (needs
#                           access to quay/quay-tests, a private repo)
#   GITHUB_TOKEN          - GitHub token for cloning quay-tests
#   WORKSPACE             - Jenkins workspace path
#
# Optional, but required if Smoke Tests will run (QUAY_MINOR_VERSION <= 17):
#   KUBECONFIG            - path to a valid kubeconfig file. The Jenkinsfile
#                           fetches this from the bastion (Capture Cluster
#                           Credentials stage) and writes it to a local file
#                           before calling this script - there is no
#                           reliable guessed path, so this is required
#                           rather than defaulted.

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

# ── Validate required env vars ───────────────────────────────────────────────
section "Validating required environment variables"
REQUIRED_VARS="QUAY_ENDPOINT OCP_ENDPOINT KUBEADMIN_PASSWORD QUAY_VERSION QUAY_MINOR_VERSION GITHUB_USER GITHUB_TOKEN WORKSPACE"
for var in $REQUIRED_VARS; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required environment variable '$var' is not set!"
        exit 1
    fi
done
echo "All required environment variables are set."

# ── Bootstrap Node.js / npm if not already available ──────────────────────────
# No admin/sudo access on this node is assumed or required: this downloads a
# self-contained Node.js binary distribution and unpacks it into the job's
# own workspace, then prepends it to PATH for the rest of THIS script's
# process only. Nothing is installed system-wide and nothing persists on the
# node outside this workspace.
section "Checking for Node.js / npm"

NODE_VERSION="20.17.0"
NODE_DIST="node-v${NODE_VERSION}-linux-x64"
NODE_INSTALL_DIR="${WORKSPACE}/.local-node"

if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    echo "Found existing Node.js: $(node -v), npm: $(npm -v)"
else
    echo "node/npm not found on PATH - bootstrapping a local, workspace-only install"
    mkdir -p "${NODE_INSTALL_DIR}"

    if [ ! -x "${NODE_INSTALL_DIR}/${NODE_DIST}/bin/node" ]; then
        echo "Downloading ${NODE_DIST}.tar.xz from nodejs.org..."
        if ! curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST}.tar.xz" \
            -o "${NODE_INSTALL_DIR}/node.tar.xz"; then
            echo "ERROR: Failed to download Node.js. Check that this node has"
            echo "       outbound network access to nodejs.org, or that a"
            echo "       working node/npm already exists on PATH."
            exit 1
        fi
        tar -xJf "${NODE_INSTALL_DIR}/node.tar.xz" -C "${NODE_INSTALL_DIR}"
        rm -f "${NODE_INSTALL_DIR}/node.tar.xz"
    else
        echo "Reusing previously bootstrapped Node.js in ${NODE_INSTALL_DIR}"
    fi

    export PATH="${NODE_INSTALL_DIR}/${NODE_DIST}/bin:${PATH}"

    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        echo "ERROR: Node.js bootstrap failed - node/npm still not found on PATH"
        echo "       after extracting to ${NODE_INSTALL_DIR}."
        exit 1
    fi

    echo "Bootstrapped Node.js: $(node -v), npm: $(npm -v)"
fi

# ── Clone quay-tests repo ─────────────────────────────────────────────────────
# quay/quay-tests is a private repo - GITHUB_TOKEN must have collaborator
# access. GITHUB_USER is intentionally NOT used in the clone URL: it may be
# an email address (contains '@'), which breaks the user:pass@host URL
# format when embedded literally - git then misparses the host entirely
# ("URL using bad/illegal format or missing URL"). GitHub only checks the
# token for HTTPS auth, so a fixed placeholder username (x-access-token)
# sidesteps this completely.
section "Cloning quay-tests repo"
QUAY_TESTS_DIR="${WORKSPACE}/quay-tests-src"
QUAY_TESTS_REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/quay/quay-tests.git"

# Clean up any previous clone
rm -rf "${QUAY_TESTS_DIR}"

CLONE_EXIT_CODE=0
git clone --branch master \
    "${QUAY_TESTS_REPO}" \
    "${QUAY_TESTS_DIR}" || CLONE_EXIT_CODE=$?

if [ $CLONE_EXIT_CODE -ne 0 ] || [ ! -d "${QUAY_TESTS_DIR}/.git" ]; then
    echo "ERROR: Failed to clone quay/quay-tests (exit code ${CLONE_EXIT_CODE})."
    echo "       Check that GITHUB_TOKEN is valid, that it has collaborator"
    echo "       access to this private repo, and that this agent has"
    echo "       network access to github.com."
    exit 1
fi

echo "Cloned quay-tests to ${QUAY_TESTS_DIR}"

# ── Common Cypress env vars (used by both API and Smoke tests) ────────────────
export CYPRESS_QUAY_ENDPOINT="${QUAY_ENDPOINT}"
export CYPRESS_QUAY_HOSTNAME="${QUAY_ENDPOINT}"
export CYPRESS_QUAY_USER="quay"
export CYPRESS_QUAY_PASSWORD="password"
export CYPRESS_QUAY_VERSION="${QUAY_VERSION}"
export CYPRESS_OCP_ENDPOINT="${OCP_ENDPOINT}"
export CYPRESS_OCP_USER="kubeadmin"
export CYPRESS_OCP_PASSWORD="${KUBEADMIN_PASSWORD}"
export CYPRESS_QUAY_NAMESPACE="quay-registry"
export CYPRESS_QUAY_IMAGE_REPOSITORY="org"
export CYPRESS_QUAY_ORG_NAME="quay"
export CYPRESS_QUAY_IMAGE_MIRROR_REPOSITORY="quay"
export CYPRESS_QUAY_ORG_MIRROR_NAME="org"

# ── API Tests ─────────────────────────────────────────────────────────────────
section "Running Cypress API Tests (Quay ${QUAY_VERSION})"

cd "${QUAY_TESTS_DIR}/quay-api-tests"
npm ci

if [ "${QUAY_MINOR_VERSION}" -le 15 ]; then
    # Old UI spec — 3.15 and below
    API_SPEC="cypress/e2e/quay_api_testing_all.cy.js"
    echo "Selected spec: ${API_SPEC} (old UI, Quay <= 3.15)"

    # Extra env vars only required by old spec
    export CYPRESS_QUAY_GLOBAL_READONLY_SUPERUSER_NAME="superglobalquay"
    export CYPRESS_QUAY_SUPERUSER_PASSWORD="password"
    export CYPRESS_QUAY_SUPER_USER_NAME="quay"
    export CYPRESS_QUAY_SUPER_USER_PASSWORD="password"
    export QUAY_SUPER_USER_TOKEN="${CYPRESS_QUAY_TOKEN:-}"
else
    # New UI spec — 3.16 and above
    API_SPEC="cypress/e2e/quay_api_testing_all_new_ui.cy.js"
    echo "Selected spec: ${API_SPEC} (new UI, Quay >= 3.16)"
fi

API_EXIT_CODE=0
npx cypress run \
    --spec "${API_SPEC}" \
    --headless \
    --browser electron \
    --env QUAY_ENDPOINT="https://${QUAY_ENDPOINT}" || API_EXIT_CODE=$?

if [ $API_EXIT_CODE -ne 0 ]; then
    echo "WARNING: Cypress API tests finished with exit code ${API_EXIT_CODE}"
else
    echo "Cypress API tests passed."
fi

# ── Smoke Tests ───────────────────────────────────────────────────────────────
# Smoke tests are only supported for Quay 3.17 and below
SMOKE_EXIT_CODE=0

if [ "${QUAY_MINOR_VERSION}" -le 17 ]; then
    section "Running Cypress Smoke Tests (Quay ${QUAY_VERSION})"

    cd "${QUAY_TESTS_DIR}/quay-frontend-tests"
    npm ci

    # Smoke tests need a real KUBECONFIG. There is no reliable guessed path
    # (kubeconfig lives on the bastion, not in this workspace) - the
    # Jenkinsfile fetches it from the bastion in the 'Capture Cluster
    # Credentials' stage and writes it to a local file before calling this
    # script, exporting KUBECONFIG to point at it. If that didn't happen,
    # fail with a clear message instead of silently pointing at a
    # non-existent guessed path.
    if [ -z "${KUBECONFIG:-}" ]; then
        echo "ERROR: KUBECONFIG is not set. Smoke tests require a valid kubeconfig -"
        echo "       the Jenkinsfile should fetch this from the bastion and export"
        echo "       KUBECONFIG before calling this script. Skipping smoke tests."
        SMOKE_EXIT_CODE=1
    elif [ ! -f "${KUBECONFIG}" ]; then
        echo "ERROR: KUBECONFIG is set to '${KUBECONFIG}' but that file does not exist."
        echo "       Skipping smoke tests."
        SMOKE_EXIT_CODE=1
    else
        echo "Using KUBECONFIG: ${KUBECONFIG}"
        npx cypress run \
            -b electron \
            -s "cypress/integration/smoke/SmokeTesting.js" \
            --headless || SMOKE_EXIT_CODE=$?

        if [ $SMOKE_EXIT_CODE -ne 0 ]; then
            echo "WARNING: Cypress Smoke tests finished with exit code ${SMOKE_EXIT_CODE}"
        else
            echo "Cypress Smoke tests passed."
        fi
    fi
else
    section "Skipping Smoke Tests (Quay ${QUAY_VERSION} > 3.17, not supported)"
fi

# ── Final exit code ───────────────────────────────────────────────────────────
# Exit non-zero if either suite failed so Jenkins marks the stage correctly
if [ $API_EXIT_CODE -ne 0 ] || [ $SMOKE_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "One or more test suites failed."
    echo "  API tests exit code:   ${API_EXIT_CODE}"
    echo "  Smoke tests exit code: ${SMOKE_EXIT_CODE}"
    exit 1
fi

echo ""
echo "$SEPARATOR"
echo "  All regression tests passed."
echo "$SEPARATOR"
echo ""