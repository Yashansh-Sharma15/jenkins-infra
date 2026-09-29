#!/bin/bash
# run_regression.sh
# Runs Cypress regression tests (API + Smoke) from the quay-tests repo.
# API spec is selected automatically based on QUAY_MINOR_VERSION:
#   3.15 and below → quay_api_testing_all.cy.js        (old UI)
#   3.16 and above → quay_api_testing_all_new_ui.cy.js (new UI)
# Smoke tests run for Quay 3.17 and below only.
#
# Required env vars (set by Jenkins before calling this script):
#   QUAY_ENDPOINT         - e.g. quay-registry.apps.<cluster>.<domain>
#   OCP_ENDPOINT          - e.g. console-openshift-console.apps.<cluster>.<domain>:6443
#   KUBEADMIN_PASSWORD    - kubeadmin password for the OCP cluster
#   QUAY_VERSION          - e.g. 3.15, 3.18
#   QUAY_MINOR_VERSION    - e.g. 15, 18  (integer, for version comparisons;
#                           a "3.10"-style value is accepted and reduced to 10;
#                           if it disagrees with QUAY_VERSION, QUAY_VERSION wins)
#   GITHUB_USER           - GitHub username (only used by the standalone clone fallback)
#   GITHUB_TOKEN          - GitHub token    (only used by the standalone clone fallback)
#   WORKSPACE             - Jenkins workspace path
#
# Optional:
#   QUAY_TESTS_ALREADY_CLONED=true  - quay-tests already cloned by Jenkins into
#                                     ${WORKSPACE}/quay-tests-src (preferred path)
#   KUBECONFIG                      - path to a valid kubeconfig file. Required
#                                     if Smoke Tests will run (QUAY_MINOR_VERSION <= 17).
#   SKIP_PREFLIGHT=true             - skip the DNS/HTTPS reachability check of QUAY_ENDPOINT
#
# System requirements: Xvfb + Cypress libraries. If missing, this script tries
# to install them itself (apt-get as root/sudo, else a rootless best-effort).

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

# Install npm dependencies. Prefers a reproducible `npm ci`, but falls back to
# `npm install` when the lock file is missing or out of sync with package.json
# (as is currently the case in quay-tests), and finally to --legacy-peer-deps
# for projects with conflicting peer dependencies.
install_deps() {
    if [ -f package-lock.json ] && npm ci --no-audit --no-fund; then
        return 0
    fi
    echo "npm ci unavailable or failed - falling back to npm install"
    if npm install --no-audit --no-fund; then
        return 0
    fi
    echo "npm install failed - retrying with --legacy-peer-deps"
    npm install --no-audit --no-fund --legacy-peer-deps
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

# ── Normalize inputs ─────────────────────────────────────────────────────────
# These values are typed into Jenkins by hand or assembled upstream, so tolerate
# the usual slips here instead of failing deep inside Cypress:
#   - whitespace in a hostname (a trailing space makes DNS fail and shows up as
#     "https://host /" in Cypress errors)
#   - a scheme or trailing slash on a hostname
#   - QUAY_MINOR_VERSION given as "3.10" instead of "10"
normalize_host() {
    local v="${1//[[:space:]]/}"
    v="${v#http://}"
    v="${v#https://}"
    printf '%s' "${v%%/*}"
}

normalize_inputs() {
    local var raw clean
    for var in QUAY_ENDPOINT OCP_ENDPOINT; do
        raw="${!var}"
        clean="$(normalize_host "$raw")"
        if [ -z "$clean" ]; then
            echo "ERROR: ${var} is empty after removing whitespace."
            return 1
        fi
        if [ "$clean" != "$raw" ]; then
            echo "NOTE: cleaned ${var}: '${raw}' -> '${clean}'"
        fi
        printf -v "$var" '%s' "$clean"
        export "$var"
    done

    QUAY_VERSION="${QUAY_VERSION//[[:space:]]/}"
    export QUAY_VERSION

    local minor="${QUAY_MINOR_VERSION//[[:space:]]/}"
    if [[ "$minor" == *.* ]]; then
        echo "NOTE: QUAY_MINOR_VERSION '${minor}' is not an integer; using '${minor##*.}' (the part after the last dot)"
        minor="${minor##*.}"
    fi
    if ! [[ "$minor" =~ ^[0-9]+$ ]]; then
        echo "ERROR: QUAY_MINOR_VERSION must be an integer such as 10 or 18 (got '${QUAY_MINOR_VERSION}')."
        return 1
    fi
    QUAY_MINOR_VERSION=$((10#$minor))
    export QUAY_MINOR_VERSION

    # QUAY_MINOR_VERSION is just the minor part of QUAY_VERSION. If they disagree
    # (e.g. version 3.14 with a leftover minor of 18), trust QUAY_VERSION, which
    # is also what the registry is reported as; otherwise the wrong spec is
    # selected and smoke tests are silently skipped.
    local ver_minor
    IFS=. read -r _ ver_minor _ <<< "$QUAY_VERSION"
    if [[ "${ver_minor:-}" =~ ^[0-9]+$ ]] && [ "$((10#$ver_minor))" != "$QUAY_MINOR_VERSION" ]; then
        echo "NOTE: QUAY_MINOR_VERSION (${QUAY_MINOR_VERSION}) does not match QUAY_VERSION (${QUAY_VERSION});"
        echo "      using $((10#$ver_minor)) from QUAY_VERSION to select the spec."
        QUAY_MINOR_VERSION=$((10#$ver_minor))
        export QUAY_MINOR_VERSION
    fi
}

# ── Preflight: can this node reach the cluster? ──────────────────────────────
# Fails fast with one clear message instead of letting Cypress report the same
# ENOTFOUND error for every test. Set SKIP_PREFLIGHT=true to bypass.
preflight() {
    local host="$QUAY_ENDPOINT" code

    # Which cluster does the kubeconfig belong to? (server URL only, no secrets)
    if [ -n "${KUBECONFIG:-}" ] && [ -f "${KUBECONFIG}" ]; then
        local api_host cluster_domain
        api_host="$(sed -n 's#^[[:space:]]*server:[[:space:]]*https\?://\([^:/[:space:]]*\).*#\1#p' "$KUBECONFIG" | head -n1)"
        if [ -n "$api_host" ]; then
            echo "Kubeconfig API server: ${api_host}"
            cluster_domain="${api_host#api.}"
            case "$host" in
                *"$cluster_domain") ;;
                *) echo "WARNING: QUAY_ENDPOINT does not end with the kubeconfig's cluster domain (${cluster_domain});"
                   echo "         the endpoint and the kubeconfig may belong to different clusters." ;;
            esac
        fi
    fi

    local ocp_host="${OCP_ENDPOINT%%:*}"
    if ! getent hosts "$ocp_host" >/dev/null 2>&1; then
        echo "WARNING: OCP_ENDPOINT host '${ocp_host}' does not resolve from this node."
    fi

    if getent hosts "$host" >/dev/null 2>&1; then
        echo "DNS OK:   $(getent hosts "$host" | head -n1)"
    else
        echo "ERROR: '${host}' does not resolve from this node ($(hostname))."
        echo "       DNS servers: $(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
        echo "       Check that the hostname is exactly the Quay route (oc get route -n quay-registry) and"
        echo "       that this node can resolve the cluster's *.apps wildcard (it may only resolve from"
        echo "       the bastion, or need an /etc/hosts entry)."
        return 1
    fi

    code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 20 "https://${host}/" 2>/dev/null || true)"
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        echo "ERROR: no HTTPS response from https://${host}/ (it resolves, but connect/TLS failed or timed out)."
        echo "       Is Quay up, and is port 443 reachable from this node?"
        return 1
    fi
    echo "HTTPS OK: https://${host}/ -> HTTP ${code}"
}

section "Normalizing inputs"
normalize_inputs || exit 1
echo "QUAY_ENDPOINT=${QUAY_ENDPOINT}  OCP_ENDPOINT=${OCP_ENDPOINT}"
echo "QUAY_VERSION=${QUAY_VERSION}  QUAY_MINOR_VERSION=${QUAY_MINOR_VERSION}"

section "Preflight: can this node reach ${QUAY_ENDPOINT}?"
if [ "${SKIP_PREFLIGHT:-}" = "true" ]; then
    echo "Skipped (SKIP_PREFLIGHT=true)."
elif ! preflight; then
    echo ""
    echo "Aborting before Cypress: the tests cannot pass while the endpoint is unreachable."
    exit 1
fi

# ── Ensure Xvfb + Cypress system libraries are available ─────────────────────
# Cypress needs Xvfb. Strategy, in order:
#   1. Already installed            -> use it.
#   2. Running as root / passwordless sudo -> apt-get install (persists on the
#      node, so this only happens once).
#   3. No privileges                -> best-effort rootless install: download
#      the .deb files with `apt-get download` and unpack them into the job
#      workspace with `dpkg -x` (re-done every run, as the workspace is wiped).
section "Checking for Xvfb (required by Cypress)"

LOCAL_XVFB_DIR="${WORKSPACE}/.local-xvfb"

# Ubuntu 24.04 renamed libasound2 to libasound2t64
if apt-cache show libasound2t64 >/dev/null 2>&1; then
    ALSA_PKG="libasound2t64"
else
    ALSA_PKG="libasound2"
fi
XVFB_PKGS="xvfb xauth libgtk-3-0 libgbm1 libnss3 libxss1 ${ALSA_PKG} libxtst6"

install_xvfb_system() {
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            SUDO="sudo"
        else
            return 1
        fi
    fi
    echo "Installing ${XVFB_PKGS} via apt-get (${SUDO:-as root})..."
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update -qq || return 1
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $XVFB_PKGS
}

install_xvfb_rootless() {
    command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1 || return 1
    echo "No root/sudo - trying rootless install into ${LOCAL_XVFB_DIR}"
    mkdir -p "${LOCAL_XVFB_DIR}/debs" "${LOCAL_XVFB_DIR}/root" "${LOCAL_XVFB_DIR}/bin" || return 1

    (
        cd "${LOCAL_XVFB_DIR}/debs" || exit 1
        # Full dependency closure, minus whatever the node already has.
        # shellcheck disable=SC2086
        for p in $(apt-cache depends --recurse --no-recommends --no-suggests \
                       --no-conflicts --no-breaks --no-replaces --no-enhances \
                       ${XVFB_PKGS} 2>/dev/null | grep '^\w' | sort -u); do
            dpkg -s "$p" >/dev/null 2>&1 || apt-get download "$p" >/dev/null 2>&1 || true
        done
        ls ./*.deb >/dev/null 2>&1 || exit 1
        for d in ./*.deb; do
            dpkg -x "$d" "${LOCAL_XVFB_DIR}/root"
        done
    ) || return 1

    [ -x "${LOCAL_XVFB_DIR}/root/usr/bin/Xvfb" ] || return 1

    # Wrapper so the relocated Xvfb finds its keyboard data.
    cat > "${LOCAL_XVFB_DIR}/bin/Xvfb" <<EOF
#!/bin/bash
exec "${LOCAL_XVFB_DIR}/root/usr/bin/Xvfb" -xkbdir "${LOCAL_XVFB_DIR}/root/usr/share/X11/xkb" "\$@"
EOF
    chmod +x "${LOCAL_XVFB_DIR}/bin/Xvfb"

    export PATH="${LOCAL_XVFB_DIR}/bin:${LOCAL_XVFB_DIR}/root/usr/bin:${PATH}"
    export LD_LIBRARY_PATH="${LOCAL_XVFB_DIR}/root/usr/lib/x86_64-linux-gnu:${LOCAL_XVFB_DIR}/root/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
}

if command -v Xvfb >/dev/null 2>&1; then
    echo "Found Xvfb: $(command -v Xvfb)"
else
    echo "Xvfb not found - attempting to install it"
    if install_xvfb_system; then
        hash -r
    elif install_xvfb_rootless; then
        hash -r
    fi

    if ! command -v Xvfb >/dev/null 2>&1; then
        echo "ERROR: Could not install Xvfb automatically (no root/sudo, and the"
        echo "       rootless install failed). Cypress cannot start without it."
        echo "       Options: ask for 'sudo apt-get install -y ${XVFB_PKGS}' on this node,"
        echo "       or run these tests inside a cypress/included Docker image."
        exit 1
    fi
    echo "Xvfb available: $(command -v Xvfb)"
fi

# ── Bootstrap Node.js / npm if not already available ──────────────────────────
# No admin/sudo access is assumed: this downloads a self-contained Node.js
# binary distribution into the job's own workspace and prepends it to PATH for
# THIS script's process only. Nothing is installed system-wide.
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

# ── Locate quay-tests repo ────────────────────────────────────────────────────
section "Locating quay-tests repo"
QUAY_TESTS_DIR="${WORKSPACE}/quay-tests-src"

if [ "${QUAY_TESTS_ALREADY_CLONED:-}" = "true" ]; then
    # Preferred path: Jenkinsfile.regression's 'Clone quay-tests' stage already
    # cloned this via Jenkins' own checkout step. Just verify it's there.
    if [ ! -d "${QUAY_TESTS_DIR}/.git" ]; then
        echo "ERROR: QUAY_TESTS_ALREADY_CLONED=true was set, but ${QUAY_TESTS_DIR}"
        echo "       does not contain a .git directory. The 'Clone quay-tests'"
        echo "       stage in Jenkinsfile.regression should have populated this."
        exit 1
    fi
    echo "Using quay-tests already cloned by Jenkins at ${QUAY_TESTS_DIR}"
else
    # Fallback for standalone/manual runs outside Jenkinsfile.regression.
    # quay/quay-tests is a private repo - GITHUB_TOKEN must be a plain PAT
    # (not a "username:password" combined value) with access to the repo.
    # GITHUB_USER is deliberately not used in the URL: it may be an email
    # address ('@' breaks the user:pass@host URL format).
    QUAY_TESTS_REPO="https://x-access-token:${GITHUB_TOKEN}@github.com/quay/quay-tests.git"

    rm -rf "${QUAY_TESTS_DIR}"

    CLONE_EXIT_CODE=0
    git clone --branch master \
        "${QUAY_TESTS_REPO}" \
        "${QUAY_TESTS_DIR}" || CLONE_EXIT_CODE=$?

    if [ $CLONE_EXIT_CODE -ne 0 ] || [ ! -d "${QUAY_TESTS_DIR}/.git" ]; then
        echo "ERROR: Failed to clone quay/quay-tests (exit code ${CLONE_EXIT_CODE})."
        echo "       Check that GITHUB_TOKEN is a valid, unexpired PAT with access"
        echo "       to this private repo, and that this node can reach github.com."
        exit 1
    fi

    echo "Cloned quay-tests to ${QUAY_TESTS_DIR}"
fi

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

API_EXIT_CODE=0

if ! install_deps; then
    echo "ERROR: Failed to install API test dependencies."
    API_EXIT_CODE=1
else
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

    # --no-install: use the project's pinned Cypress from node_modules and
    # fail loudly instead of silently downloading the latest version.
    npx --no-install cypress run \
        --spec "${API_SPEC}" \
        --headless \
        --browser electron \
        --env QUAY_ENDPOINT="https://${QUAY_ENDPOINT}" || API_EXIT_CODE=$?
fi

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

    # Smoke tests need a real KUBECONFIG, which Jenkinsfile.regression decodes
    # from the KUBECONFIG_B64 parameter and exports. If that didn't happen,
    # fail with a clear message instead of pointing at a guessed path.
    if [ -z "${KUBECONFIG:-}" ]; then
        echo "ERROR: KUBECONFIG is not set. Smoke tests require a valid kubeconfig."
        echo "       Skipping smoke tests."
        SMOKE_EXIT_CODE=1
    elif [ ! -f "${KUBECONFIG}" ]; then
        echo "ERROR: KUBECONFIG is set to '${KUBECONFIG}' but that file does not exist."
        echo "       Skipping smoke tests."
        SMOKE_EXIT_CODE=1
    elif ! install_deps; then
        echo "ERROR: Failed to install smoke test dependencies."
        SMOKE_EXIT_CODE=1
    else
        echo "Using KUBECONFIG: ${KUBECONFIG}"
        npx --no-install cypress run \
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