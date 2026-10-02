#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# platform: external on OCI, provisioned by CAPOCI -- a Cluster API provider
# the installer has never been compiled against. Mirrors
# upi/external/examples/oci-capoci/scripts/run-create-command.sh.
#
# `set -x` is deliberately absent. Two values in this script are
# credential-equivalent and a trace line would publish either of them: the
# pre-authenticated request URL over the bootstrap ignition, and anything read
# out of the cluster profile.
#

trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

source "${SHARED_DIR}/init-fn.sh"
source "${SHARED_DIR}/capi-fn.sh"

install_jq
install_yq4
capi_install_oci_cli

export CAPI_ARTIFACTS="${PLATFORM_EXTERNAL_CAPI_ARTIFACTS}"

INSTALL_DIR=/tmp/install-dir
EXAMPLE_DIR=$(capi_example_dir "${PLATFORM_EXTERNAL_CAPI_EXAMPLE}")

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
BASE_DOMAIN=$(<"${SHARED_DIR}/BASE_DOMAIN")
export BASE_DOMAIN

capi_oci_cli_config

# ------------------------------------------------- the one unsolved prerequisite

# There is no published RHCOS artifact for OCI. Everything else in this step
# works or fails for a reason inside this repository; this one does not, and
# saying so here is better than a two-hour wait for machines that cannot boot.
#
# The wanted fix is explicitly NOT an OCI special case: a generic per-provider
# artifact set with OPENSHIFT_INSTALL_RHCOS_ARTIFACTS_JSON as the override
# shape, so the next partner does not need a second exception.
if [[ -r "${CLUSTER_PROFILE_DIR}/rhcos-image-id" ]]; then
  OCI_IMAGE_ID=$(<"${CLUSTER_PROFILE_DIR}/rhcos-image-id")
fi
if [[ -z ${OCI_IMAGE_ID:-} ]]; then
  capi_log "OCI_IMAGE_ID is unset and the cluster profile has no rhcos-image-id."
  capi_log ""
  capi_log "There is no published RHCOS artifact for OCI, so no machine in this"
  capi_log "install can boot. This is a product gap, not a job configuration"
  capi_log "error: see upi/external/examples/oci-capoci/docs/boot-image.md."
  capi_log ""
  capi_log "Until an image exists, run this job with"
  capi_log "PLATFORM_EXTERNAL_CAPI_INFRA_ONLY=true, which exercises the network,"
  capi_log "the API load balancer, DNS and the infraReady hook and boots nothing."
  exit 1
fi
export OCI_IMAGE_ID

export OCI_IGNITION_BUCKET="${OCI_IGNITION_BUCKET:-${CLUSTER_NAME}-ignition}"

# ------------------------------------------------------------ install directory

mkdir -p "${INSTALL_DIR}"
cp -v "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml"
cp -rv "${EXAMPLE_DIR}/external-install" "${INSTALL_DIR}/external-install"

# CAPOCI's API signing key, for the LOCAL control plane only.
#
# It is never delivered to the installed cluster: the installer applies
# external-install/ to a temporary envtest etcd and kube-apiserver on this
# pod, and nothing copies Secrets from there to the target. The in-cluster
# CCM credential is a separate object the infraReady hook renders.
capi_oci_identity_secret "${INSTALL_DIR}/external-install/00_oci-credentials.yaml"

capi_stage_capoci "${EXAMPLE_DIR}" \
  "${PLATFORM_EXTERNAL_CAPI_PROVIDER_IMAGE}" \
  "${PLATFORM_EXTERNAL_CAPI_COMPONENTS_URL}"

# ------------------------------------------------------------------- preflight

# There is no preProvision hook -- the contract offers infraReady,
# postProvision and preDestroy only (pkg/infrastructure/external/hooks/hooks.go)
# and all three run after the provider has started creating things. So anything
# that should stop a run before it spends money has to live in the operator's
# own automation, which here means this step. That is a finding about
# `platform: external` rather than a quirk of OCI; see
# upi/external/examples/oci-capoci/docs/capi-requirements.md.

compartment_state=$(oci iam compartment get --compartment-id "${OCI_COMPARTMENT_ID}" \
  --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
if [[ ${compartment_state} != "ACTIVE" ]]; then
  capi_log "ERROR: compartment ${OCI_COMPARTMENT_ID} is ${compartment_state:-unreachable}, not ACTIVE"
  exit 1
fi

for probe in \
  "network vcn list|virtual-network-family (CAPOCI builds the VCN)" \
  "nlb network-load-balancer list|load-balancers (the API server endpoint)" \
  "compute instance list|instance-family (machines)" \
  "bv volume list|volume-family (the CSI driver)"; do
  cmd=${probe%%|*}
  what=${probe##*|}
  # shellcheck disable=SC2086
  if ! oci ${cmd} --compartment-id "${OCI_COMPARTMENT_ID}" --limit 1 >/dev/null 2>&1; then
    capi_log "ERROR: cannot list ${what} in ${OCI_COMPARTMENT_ID}"
    capi_log "       the profile's identity has no policy on this compartment"
    exit 1
  fi
  capi_log "  can read ${what}"
done

if ! oci os bucket get --bucket-name "${OCI_IGNITION_BUCKET}" >/dev/null 2>&1; then
  capi_log "Creating the ignition bucket ${OCI_IGNITION_BUCKET}"
  oci os bucket create --compartment-id "${OCI_COMPARTMENT_ID}" \
    --name "${OCI_IGNITION_BUCKET}" --public-access-type NoPublicAccess >/dev/null
fi
echo "${OCI_IGNITION_BUCKET}" > "${SHARED_DIR}/OCI_IGNITION_BUCKET"

# ----------------------------------------------------------------- phase one

capi_log "Phase 1: create manifests"
openshift-install create manifests --log-level=debug --dir="${INSTALL_DIR}"

INFRA_ID=$(capi_read_infra_id "${INSTALL_DIR}")
echo "${INFRA_ID}" > "${SHARED_DIR}/INFRA_ID"
capi_log "Infrastructure ID ${INFRA_ID}"

CLUSTER_DOMAIN="${CLUSTER_NAME}.${BASE_DOMAIN}"

# An OCI VCN dnsLabel is not a domain name: alphanumeric only, must start with
# a letter, 15 characters maximum, and unique within the compartment. The
# infrastructure ID has hyphens and can exceed that.
VCN_DNS_LABEL=$(printf '%s' "${INFRA_ID}" | tr -cd '[:alnum:]' | cut -c1-15)
if [[ ! ${VCN_DNS_LABEL} =~ ^[a-zA-Z] ]]; then
  VCN_DNS_LABEL="v${VCN_DNS_LABEL}"
  VCN_DNS_LABEL=${VCN_DNS_LABEL:0:15}
fi

# Keep this list and the sed's file list identical -- they are two statements
# of the same fact and they drift silently. Scoping the assertion to the
# substitution's own inputs is deliberate: a check that walked the whole
# directory failed twice in the pilot on files that merely NAME a placeholder,
# a README and a comment, neither of which is a real drift.
SUBST_INPUTS=(
  "${INSTALL_DIR}/external-install/cluster.yaml"
  "${INSTALL_DIR}/external-install/00_oci-credentials.yaml"
  "${INSTALL_DIR}"/external-install/machines/*.yaml
)
sed -i \
  -e "s/CLUSTER-ID/${INFRA_ID}/g" \
  -e "s|COMPARTMENT-OCID|${OCI_COMPARTMENT_ID}|g" \
  -e "s|IMAGE-OCID|${OCI_IMAGE_ID}|g" \
  -e "s/REGION/${OCI_REGION}/g" \
  -e "s/VCNDNSLABEL/${VCN_DNS_LABEL}/g" \
  -e "s/CLUSTERDNS/${CLUSTER_DOMAIN}/g" \
  "${SUBST_INPUTS[@]}"

capi_assert_no_placeholders \
  'CLUSTER-ID|COMPARTMENT-OCID|IMAGE-OCID|CLUSTERDNS|VCNDNSLABEL' \
  "${SUBST_INPUTS[@]}"

# The credential Secret is a substitution input and must not be published.
cp -v "${INSTALL_DIR}/external-install/cluster.yaml" "${ARTIFACT_DIR}/capi-cluster.yaml"

# ----------------------------------------------------------------- phase two

capi_log "Phase 2: create ignition-configs"
openshift-install create ignition-configs --log-level=debug --dir="${INSTALL_DIR}"

BOOTSTRAP_IGN="${INSTALL_DIR}/bootstrap.ign"
[[ -s ${BOOTSTRAP_IGN} ]] || { capi_log "ERROR: no bootstrap.ign"; exit 1; }

# Size and hash only. The file is the cluster's day-0 secret material.
BOOTSTRAP_BYTES=$(wc -c <"${BOOTSTRAP_IGN}")
BOOTSTRAP_SHA=$(sha256sum "${BOOTSTRAP_IGN}" | cut -d' ' -f1)
capi_log "bootstrap.ign: ${BOOTSTRAP_BYTES} bytes, sha256 ${BOOTSTRAP_SHA}"

# --------------------------------------------------------------- phase two.5
#
# Offload. This is the part with no AWS equivalent: CAPOCI has no
# object-storage client at all, and OCI caps instance metadata at 32,000
# bytes.

OBJECT_NAME="${INFRA_ID}/bootstrap.ign"

oci os object put \
  --bucket-name "${OCI_IGNITION_BUCKET}" \
  --name "${OBJECT_NAME}" \
  --file "${BOOTSTRAP_IGN}" \
  --content-type application/json \
  --force >/dev/null

capi_log "uploaded ${OBJECT_NAME} to ${OCI_IGNITION_BUCKET}"

# The pre-authenticated request URL is an UNAUTHENTICATED credential over
# everything in bootstrap.ign. It is never echoed, it expires in two hours,
# and the preDestroy hook revokes it; the expiry is only the backstop for
# when that does not run.
PAR_EXPIRY=$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)

PAR_JSON=$(oci os preauth-request create \
  --bucket-name "${OCI_IGNITION_BUCKET}" \
  --name "${INFRA_ID}-bootstrap" \
  --object-name "${OBJECT_NAME}" \
  --access-type ObjectRead \
  --time-expires "${PAR_EXPIRY}" 2>/dev/null)

PAR_ID=$(printf '%s' "${PAR_JSON}" | jq -r '.data.id')
PAR_PATH=$(printf '%s' "${PAR_JSON}" | jq -r '.data."access-uri"')
unset PAR_JSON

if [[ -z ${PAR_PATH} || ${PAR_PATH} == "null" ]]; then
  capi_log "ERROR: could not mint a pre-authenticated request for ${OBJECT_NAME}"
  exit 1
fi

PAR_URL="https://objectstorage.${OCI_REGION}.oraclecloud.com${PAR_PATH}"

# The pointer config -- roughly 300 bytes against OCI's 23,900-byte raw
# budget. Written by python so the URL is never a shell word.
PAR_URL="${PAR_URL}" python3 - "${BOOTSTRAP_IGN}" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "ignition": {
        "version": "3.2.0",
        "config": {"merge": [{"source": os.environ["PAR_URL"]}]},
    }
}))
PY

unset PAR_URL PAR_PATH

STUB_BYTES=$(wc -c <"${BOOTSTRAP_IGN}")
capi_log "replaced bootstrap.ign with a ${STUB_BYTES}-byte pointer config"
if [[ ${STUB_BYTES} -gt 23900 ]]; then
  capi_log "ERROR: the pointer config exceeds OCI's raw userdata budget"
  exit 1
fi

# What preDestroy has to clean up. The PAR id is an identifier, not the URL,
# so this file is not itself a credential.
mkdir -p "${INSTALL_DIR}/.external-hook-state"
jq -n \
  --arg bucket "${OCI_IGNITION_BUCKET}" \
  --arg object "${OBJECT_NAME}" \
  --arg par "${PAR_ID}" \
  --arg sha "${BOOTSTRAP_SHA}" \
  '{ignitionBucket:$bucket, ignitionObject:$object, ignitionParId:$par, ignitionSha256:$sha}' \
  >"${INSTALL_DIR}/.external-hook-state/bootstrap-ignition.json"
unset PAR_ID

# --------------------------------------------------------------- phase three

if [[ ${PLATFORM_EXTERNAL_CAPI_INFRA_ONLY} == "true" ]]; then
  capi_log "OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY: stopping at infrastructureReady"
  export OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY=true
else
  # Day-0 workers are Cluster API Machines with no Machine object in the
  # installed cluster, so nothing auto-approves their kubelet CSRs. This has
  # to overlap `create cluster`, which is why it is a background loop rather
  # than a step.
  capi_start_csr_approver "${INSTALL_DIR}"
  trap 'capi_stop_csr_approver' EXIT
fi

capi_log "Phase 3: create cluster"
set +o errexit
openshift-install create cluster --log-level=debug --dir="${INSTALL_DIR}" &
wait "$!"
ret=$?
set -o errexit

capi_stop_csr_approver

cp -v "${INSTALL_DIR}/.openshift_install.log" "${ARTIFACT_DIR}/openshift_install.log" 2>/dev/null || true
if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
  cp -v "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig"
fi

capi_save_destroy_state "${INSTALL_DIR}"

exit "${ret}"
