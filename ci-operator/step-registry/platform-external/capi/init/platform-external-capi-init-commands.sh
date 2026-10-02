#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Shared functions for the platform-external CAPI workflows.
#
# Mirrors platform-external-pre-init: steps do not share a filesystem, so
# anything more than one step needs has to be written here and sourced there.
#

echo "Creating shared CAPI function file: ${SHARED_DIR}/capi-fn.sh"

cat << 'EOF' > "${SHARED_DIR}/capi-fn.sh"
# shellcheck shell=bash

# Where the upi-installer image keeps the installer repository's upi/ tree.
# This is the whole point of running these steps from upi-installer rather
# than from installer: in a presubmit the examples under test are the ones
# from the pull request, not a copy fetched from a branch somewhere.
export CAPI_EXAMPLES_ROOT=${CAPI_EXAMPLES_ROOT:-/var/lib/openshift-install/upi/external/examples}

# Per-pod scratch. Never ${SHARED_DIR}: the provider controller binary is
# around 100 MB and ${SHARED_DIR} is Secret-backed.
export CAPI_ARTIFACTS=${CAPI_ARTIFACTS:-/tmp/capi-artifacts}

function capi_log() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}
export -f capi_log

# capi_example_dir <example-name>
#
# Resolves and validates an example directory, e.g. aws-capa or oci-capoci.
# Fails here rather than letting a later cp produce a half-populated install
# directory.
function capi_example_dir() {
  local example=$1
  local dir="${CAPI_EXAMPLES_ROOT}/${example}"
  if [[ ! -d ${dir} ]]; then
    capi_log "ERROR: no example at ${dir}"
    capi_log "available: $(cd "${CAPI_EXAMPLES_ROOT}" 2>/dev/null && printf '%s ' */)"
    return 1
  fi
  echo "${dir}"
}
export -f capi_example_dir

# capi_stage_embedded_provider <provider>
#
# Stages a provider the installer binary already embeds -- today that is every
# integrated provider, and the one the AWS arm uses. `extract cluster-api` is
# a hidden command (cmd/openshift-install/extract.go) added by the pilot for
# exactly this: it makes the External platform testable against a provider
# build the installer itself produced, rather than against an unknown binary
# downloaded from somewhere.
function capi_stage_embedded_provider() {
  local provider=$1
  mkdir -p "${CAPI_ARTIFACTS}"
  capi_log "Extracting embedded Cluster API provider '${provider}' to ${CAPI_ARTIFACTS}"
  openshift-install extract cluster-api "${provider}" --dest-dir="${CAPI_ARTIFACTS}"

  # Report what was staged by name, size and hash. Never contents: this is the
  # project's standing logging rule, and a components manifest is large enough
  # that dumping it would bury everything else in the step log anyway.
  ( cd "${CAPI_ARTIFACTS}" && sha256sum ./* | sed 's|^|  staged |' )
}
export -f capi_stage_embedded_provider

# capi_stage_provider_image <image-pullspec> <binary-path-in-image> <dest-name>
#
# Stages a provider the installer does not embed, by extracting its controller
# binary out of the provider's own container image. This is the path any
# non-integrated partner provider has to take, and it is deliberately the same
# mechanism for all of them.
function capi_stage_provider_image() {
  local image=$1 src=$2 dest=$3
  mkdir -p "${CAPI_ARTIFACTS}"
  capi_log "Extracting ${src} from ${image}"
  oc image extract "${image}" --path "${src}:${CAPI_ARTIFACTS}/" --confirm
  mv -f "${CAPI_ARTIFACTS}/$(basename "${src}")" "${CAPI_ARTIFACTS}/${dest}"
  chmod 0755 "${CAPI_ARTIFACTS}/${dest}"
  capi_log "staged $(sha256sum "${CAPI_ARTIFACTS}/${dest}")"
}
export -f capi_stage_provider_image

# capi_stage_capoci <example-dir> <controller-image> <components-url>
#
# Stages the three files the OCI example's install-config names, in one place
# because the install step and the destroy step both need all three and a
# teardown staged differently from its install is a teardown that cannot run.
#
#   capoci-shim.sh                      binaryPath -- a wrapper, not the
#                                       controller, because the installer
#                                       passes --health-addr and CAPOCI's
#                                       flag is --health-probe-bind-address
#   cluster-api-provider-oci            the controller the shim execs
#   oci-infrastructure-components.yaml  componentsPath -- the CRDs
#
# The shim comes from the example rather than being written here on purpose:
# it is part of the published artifact set a partner copies, so CI running a
# different copy of it would be testing something nobody ships.
function capi_stage_capoci() {
  local example_dir=$1 image=$2 components_url=$3
  mkdir -p "${CAPI_ARTIFACTS}"

  cp "${example_dir}/scripts/capoci-shim.sh" "${CAPI_ARTIFACTS}/capoci-shim.sh"
  chmod 0755 "${CAPI_ARTIFACTS}/capoci-shim.sh"

  # The two env names are the ref's, not invented here, and both the install
  # ref and the destroy ref declare them with the same defaults -- staging the
  # binary from a different path or under a different name in the two steps
  # produces a teardown that cannot start the provider.
  capi_stage_provider_image "${image}" \
    "${PLATFORM_EXTERNAL_CAPI_PROVIDER_BINARY:-/manager}" \
    "${PLATFORM_EXTERNAL_CAPI_PROVIDER_BINARY_NAME:-cluster-api-provider-oci}"

  capi_log "Fetching CAPOCI components from ${components_url}"
  curl -fsSL --retry 3 --retry-delay 5 -o "${CAPI_ARTIFACTS}/oci-infrastructure-components.yaml" \
    "${components_url}"

  ( cd "${CAPI_ARTIFACTS}" && sha256sum ./* | sed 's|^|  staged |' )
}
export -f capi_stage_capoci

# capi_read_infra_id <install-dir>
#
# Infrastructure.status.infrastructureName, from the generated manifests.
#
# grep -oE emits only the matched line and nothing else, which matters:
# the output of `create manifests` is a credential store -- it holds the
# machine-config-server TLS private key, a CA private key, the pull secret and
# the kubeadmin password hash. Read it by pattern, never by range.
function capi_read_infra_id() {
  local dir=$1 infra_id
  infra_id=$(grep -oE '^  infrastructureName: .*' \
    "${dir}/manifests/cluster-infrastructure-02-config.yml" | awk '{print $2}')
  if [[ -z ${infra_id} ]]; then
    capi_log "ERROR: could not read infrastructureName from ${dir}/manifests"
    return 1
  fi
  echo "${infra_id}"
}
export -f capi_read_infra_id

# capi_assert_no_placeholders <token-regex> <file>...
#
# An unsubstituted placeholder reaches the cloud as a literal and is only
# noticed once resources exist. Scope the check to the files the substitution
# actually rewrites: checking files that are not substitution inputs cannot
# detect a real drift, only invent one -- that mistake cost the pilot two runs,
# first on a README naming the placeholders and then on a comment mentioning
# one.
function capi_assert_no_placeholders() {
  local pattern=$1; shift
  if grep -qE "${pattern}" "$@"; then
    capi_log "ERROR: placeholders survived substitution in:"
    grep -lE "${pattern}" "$@"
    return 1
  fi
}
export -f capi_assert_no_placeholders

# capi_save_install_config_redacted <install-config> <dest>
#
# Publishes the install-config to the artifact directory without its
# credentials. Allow-list by line, the same way platform-external-pre-conf
# does it.
function capi_save_install_config_redacted() {
  grep -v "password\|username\|pullSecret\|{\"auths\":{\|httpProxy\|httpsProxy\|sshKey\|ssh-rsa\|ssh-ed25519" \
    "$1" > "$2" || true
}
export -f capi_save_install_config_redacted

# capi_install_oci_cli
#
# The upi-installer image carries aws, gcloud, ibmcloud, az and govc, but no
# oci. That is not an oversight to work around quietly: `platform: external`
# exists so a partner cloud needs no installer code, and the CI image having a
# CLI for every integrated cloud and none for the partner ones is the same
# asymmetry seen from the tooling side.
#
# Installed here rather than added to the image because it is around 100 MB of
# Python dependencies that every other consumer of upi-installer would pay
# for. If a second OCI job appears, move it into the image instead.
#
# Pinned, because an unpinned CLI makes a job that worked yesterday fail today
# for a reason that has nothing to do with the pull request under test.
function capi_install_oci_cli() {
  if command -v oci >/dev/null 2>&1; then
    capi_log "oci CLI already present: $(oci --version 2>/dev/null)"
    return 0
  fi
  capi_log "Installing the OCI CLI"
  export PATH="${HOME}/.local/bin:${PATH}"
  if ! pip3 install --user --quiet "oci-cli==${OCI_CLI_VERSION:-3.68.0}"; then
    capi_log "ERROR: could not install the OCI CLI. The hooks and this step both"
    capi_log "       need it; there is no fallback. If this is a persistent"
    capi_log "       network restriction, the fix is to add the CLI to"
    capi_log "       images/installer/Dockerfile.upi.ci rather than to retry here."
    return 1
  fi
  command -v oci >/dev/null 2>&1 || { capi_log "ERROR: oci is still not on PATH"; return 1; }
  capi_log "oci CLI: $(oci --version)"
}
export -f capi_install_oci_cli

# capi_oci_cli_config
#
# Assembles an OCI CLI configuration from the cluster profile.
#
# The profile holds one field per file -- region, user, fingerprint,
# tenancy-id, oci-privatekey -- and both the oci CLI and CAPOCI want them
# combined. Written with a redirect so no value is ever an argument and
# therefore no value can reach a trace or a log line. The key is copied by
# path.
#
# Exports OCI_CLI_CONFIG_FILE and OCI_CLI_REGION. The CLI does not read
# OCI_REGION -- that is this project's own variable -- and left to itself it
# uses the config file's home region, which makes every call act on the wrong
# region while looking like it worked.
function capi_oci_cli_config() {
  local profile=${CLUSTER_PROFILE_DIR} dir=/tmp/oci
  mkdir -p "${dir}"
  chmod 0700 "${dir}"

  cp "${profile}/oci-privatekey" "${dir}/oci_api_key.pem"
  chmod 0600 "${dir}/oci_api_key.pem"

  {
    echo "[DEFAULT]"
    echo "user=$(<"${profile}/user")"
    echo "fingerprint=$(<"${profile}/fingerprint")"
    echo "tenancy=$(<"${profile}/tenancy-id")"
    echo "region=$(<"${profile}/region")"
    echo "key_file=${dir}/oci_api_key.pem"
  } > "${dir}/config"
  chmod 0600 "${dir}/config"

  export OCI_CLI_CONFIG_FILE="${dir}/config"
  export OCI_CLI_PROFILE=DEFAULT
  export OCI_CLI_REGION
  OCI_CLI_REGION=$(<"${profile}/region")
  export OCI_REGION="${OCI_CLI_REGION}"
  export OCI_COMPARTMENT_ID
  OCI_COMPARTMENT_ID=$(<"${profile}/compartment-id")

  capi_log "OCI CLI configured for region ${OCI_CLI_REGION} from ${profile}"
}
export -f capi_oci_cli_config

# capi_oci_identity_secret <dest> <secret-name>
#
# Renders the OCIClusterIdentity Secret CAPOCI authenticates with.
#
# OCICluster.spec.identityRef names an OCIClusterIdentity, which names a
# Secret holding tenancy/user/fingerprint/key/region (CAPOCI
# cloud/util/util.go). The identity object itself is in the example's
# cluster.yaml in the clear because it holds nothing secret; only this file
# does.
#
# Built in python rather than in shell so the private key is read and written
# without ever becoming a shell word: there is no interpolation, no echo and
# no argument that could be traced.
function capi_oci_identity_secret() {
  local dest=$1 name=${2:-CLUSTER_ID-oci-credentials}
  python3 - "${CLUSTER_PROFILE_DIR}" "${dest}" "${name}" <<'PY'
import pathlib, sys, yaml

profile, dest, name = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
doc = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": name, "namespace": "openshift-cluster-api-guests"},
    "type": "Opaque",
    "stringData": {
        "tenancy": (profile / "tenancy-id").read_text().strip(),
        "user": (profile / "user").read_text().strip(),
        "key": (profile / "oci-privatekey").read_text(),
        "fingerprint": (profile / "fingerprint").read_text().strip(),
        "region": (profile / "region").read_text().strip(),
    },
}
dest.write_text(yaml.safe_dump(doc, default_flow_style=False))
PY
  chmod 0600 "${dest}"
  capi_log "wrote the OCIClusterIdentity Secret to ${dest} ($(wc -c <"${dest}") bytes)"
}
export -f capi_oci_identity_secret

# capi_start_csr_approver <install-dir>
#
# Approves pending certificate signing requests for as long as the install is
# running, in the background.
#
# This is a known gap, not an implementation detail. There is no
# cloud-specific machine approver on `platform: external`:
# cluster-machine-approver auto-approves a kubelet CSR only when a matching
# Machine object exists, and the installer generates no MachineSets for this
# platform, so day-0 workers never get one. Without this the install reaches
# bootstrap-complete and then waits out its timeout with workers that have
# requested a certificate nobody will sign.
#
# It has to run concurrently with `create cluster`, which is why it is a
# background loop here rather than a step of its own -- a step cannot overlap
# the step before it. The standalone platform-external-capi-approve-csr ref
# exists for the after-the-fact case and is idempotent with this.
#
# Blanket approval is acceptable *in CI only*, on a cluster whose network no
# untrusted party can reach. It is not a pattern to copy into a product: the
# upstream ask is a webhook that compares a CSR against the instance it claims
# to come from.
function capi_start_csr_approver() {
  local dir=$1
  (
    export KUBECONFIG="${dir}/auth/kubeconfig"
    while true; do
      sleep 30
      [[ -s ${KUBECONFIG} ]] || continue
      pending=$(oc get csr -o json 2>/dev/null |
        jq -r '.items[] | select(.status == {} or (.status | has("certificate") | not)) | .metadata.name' 2>/dev/null)
      [[ -n ${pending} ]] || continue
      # shellcheck disable=SC2086
      oc adm certificate approve ${pending} >/dev/null 2>&1 || true
      echo "csr-approver: approved $(wc -w <<<"${pending}") request(s)"
    done
  ) &
  CAPI_CSR_APPROVER_PID=$!
  export CAPI_CSR_APPROVER_PID
  capi_log "Started the background CSR approver (pid ${CAPI_CSR_APPROVER_PID})"
}
export -f capi_start_csr_approver

# capi_stop_csr_approver
function capi_stop_csr_approver() {
  if [[ -n ${CAPI_CSR_APPROVER_PID:-} ]]; then
    kill "${CAPI_CSR_APPROVER_PID}" 2>/dev/null || true
    wait "${CAPI_CSR_APPROVER_PID}" 2>/dev/null || true
    capi_log "Stopped the background CSR approver"
  fi
}
export -f capi_stop_csr_approver

# capi_save_destroy_state <install-dir>
#
# Hands the destroy step everything it needs and nothing it does not.
#
# `destroy cluster` on this platform is a restore-then-delete: it rebuilds the
# local control plane from .clusterapi_output/ and asks the provider to delete
# the Cluster. Those artifacts are written by the install, in a pod that will
# not exist when destroy runs, so they have to travel.
#
# What travels is bounded on purpose. ${SHARED_DIR} is Secret-backed and the
# install directory is a credential store; only the three things destroy
# actually reads are copied, and collectManifests has already excluded every
# Secret from .clusterapi_output (clusterapi.go:696-700).
function capi_save_destroy_state() {
  local dir=$1

  if [[ -f ${dir}/metadata.json ]]; then
    cp "${dir}/metadata.json" "${SHARED_DIR}/metadata.json"
  fi

  if compgen -G "${dir}/.clusterapi_output/*.yaml" >/dev/null; then
    tar -czf "${SHARED_DIR}/clusterapi-output.tar.gz" -C "${dir}" \
      --exclude='*ecret*' .clusterapi_output
    capi_log "saved .clusterapi_output ($(wc -c <"${SHARED_DIR}/clusterapi-output.tar.gz") bytes compressed)"
  else
    capi_log "WARNING: no .clusterapi_output in ${dir}; destroy will have nothing to restore"
  fi

  if [[ -d ${dir}/.external-hook-state ]]; then
    # Identifiers only -- bucket, object name, PAR id, ignition digest. Not
    # the pre-authenticated URL, which is credential-equivalent and is never
    # written anywhere.
    tar -czf "${SHARED_DIR}/external-hook-state.tar.gz" -C "${dir}" .external-hook-state
  fi
}
export -f capi_save_destroy_state

# capi_restore_destroy_state <install-dir>
#
# The counterpart. Rebuilds the parts of the install directory `destroy
# cluster` reads, from ${SHARED_DIR} and from the example in the image.
function capi_restore_destroy_state() {
  local dir=$1 example_dir=$2
  mkdir -p "${dir}"

  if [[ ! -f ${SHARED_DIR}/metadata.json ]]; then
    capi_log "no ${SHARED_DIR}/metadata.json: the install never got far enough to"
    capi_log "create a cluster, so there is nothing for destroy to remove."
    return 1
  fi
  cp "${SHARED_DIR}/metadata.json" "${dir}/metadata.json"

  if [[ -f ${SHARED_DIR}/clusterapi-output.tar.gz ]]; then
    tar -xzf "${SHARED_DIR}/clusterapi-output.tar.gz" -C "${dir}"
  fi
  if [[ -f ${SHARED_DIR}/external-hook-state.tar.gz ]]; then
    tar -xzf "${SHARED_DIR}/external-hook-state.tar.gz" -C "${dir}"
  fi

  # The preDestroy hook's program path is recorded in metadata.json relative
  # to the install directory, and it lives in the example rather than in
  # anything the install wrote. Copy the example's tree back so the path
  # resolves; the hook scripts take no substitution, so the image's copy is
  # the same bytes the install ran.
  if [[ -d ${example_dir}/external-install/hooks ]]; then
    mkdir -p "${dir}/external-install"
    cp -r "${example_dir}/external-install/hooks" "${dir}/external-install/hooks"
  fi
}
export -f capi_restore_destroy_state
EOF

echo "Wrote ${SHARED_DIR}/capi-fn.sh"
