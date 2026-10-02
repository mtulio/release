#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# platform: external on AWS, provisioned by CAPA as a user-supplied Cluster
# API provider. Mirrors upi/external/examples/aws-capa/scripts/run-create-command.sh.
#

trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

source "${SHARED_DIR}/init-fn.sh"
source "${SHARED_DIR}/capi-fn.sh"

install_jq
install_yq4
install_awscli

export CAPI_ARTIFACTS="${PLATFORM_EXTERNAL_CAPI_ARTIFACTS}"

: "${LEASED_RESOURCE:?no AWS region lease}"
export AWS_REGION="${LEASED_RESOURCE}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# Passed by path, never read. The installer and CAPA both read it; this step
# does not, and `set -x` is deliberately not enabled anywhere in this script.
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

INSTALL_DIR=/tmp/install-dir
EXAMPLE_DIR=$(capi_example_dir "${PLATFORM_EXTERNAL_CAPI_EXAMPLE}")

mkdir -p "${INSTALL_DIR}"
cp -v "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml"
cp -rv "${EXAMPLE_DIR}/external-install" "${INSTALL_DIR}/external-install"

CLUSTER_NAME=$(<"${SHARED_DIR}/CLUSTER_NAME")
BASE_DOMAIN=$(<"${SHARED_DIR}/BASE_DOMAIN")
capi_log "Installing ${CLUSTER_NAME}.${BASE_DOMAIN} from example ${PLATFORM_EXTERNAL_CAPI_EXAMPLE}"

# --- phase zero: artifacts

capi_stage_embedded_provider aws

# --- phase zero: DNS zone

# The postProvision hook publishes the *.apps wildcard, and its zone is an
# argument rather than installer knowledge -- the installer never reads it.
# The example ships the pilot's own zone ID, so CI has to replace it with the
# one that actually holds this job's base domain.
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${BASE_DOMAIN}." \
  --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id | [0]" --output text | awk -F/ '{print $NF}')

if [[ -z ${HOSTED_ZONE_ID} || ${HOSTED_ZONE_ID} == "None" ]]; then
  capi_log "ERROR: no Route 53 hosted zone for ${BASE_DOMAIN}"
  exit 1
fi
capi_log "Using hosted zone ${HOSTED_ZONE_ID} for ${BASE_DOMAIN}"

# yq rather than sed: the argument is one element of a sequence and the value
# being replaced is a zone ID that could appear elsewhere in the file.
HOSTED_ZONE_ID="${HOSTED_ZONE_ID}" yq4 --inplace '
  .platform.external.clusterAPI.hooks.postProvision.args =
    (.platform.external.clusterAPI.hooks.postProvision.args
      | map(select(test("^--input-dns-zone=") | not))
      + ["--input-dns-zone=" + strenv(HOSTED_ZONE_ID)])
' "${INSTALL_DIR}/install-config.yaml"

if [[ $(grep -c -- "--input-dns-zone=${HOSTED_ZONE_ID}" "${INSTALL_DIR}/install-config.yaml") -ne 1 ]]; then
  capi_log "ERROR: the postProvision DNS zone argument was not set"
  exit 1
fi

# --- phase zero: CCM

# Fills the cloud controller manager image and its credentials into
# external-install/extra-manifests/. Must run before `create manifests`: the
# installer folds extra-manifests/ into the generated openshift manifests, and
# the pull secret this script needs lives in install-config.yaml, which
# `create manifests` consumes and removes.
#
# Without it the install reaches a healthy API server and three registered
# masters and then stops, because nothing removes the
# node.cloudprovider.kubernetes.io/uninitialized taint.
"${EXAMPLE_DIR}/scripts/prepare-ccm.sh" "${INSTALL_DIR}"

# --- phase one: create manifests

capi_log "Phase 1: create manifests"
openshift-install create manifests --log-level=debug --dir="${INSTALL_DIR}"

INFRA_ID=$(capi_read_infra_id "${INSTALL_DIR}")
echo "${INFRA_ID}" > "${SHARED_DIR}/INFRA_ID"
capi_log "Infrastructure ID ${INFRA_ID}"

# pkg/asset/rhcos/image.go returns "" for platform: external, so the boot
# image has to come from somewhere. The installer's own stream metadata is
# that somewhere, and it is the same source the integrated AWS jobs use.
RHCOS_AMI=$(openshift-install coreos print-stream-json |
  jq -r ".architectures.x86_64.images.aws.regions[\"${AWS_REGION}\"].image")

if [[ -z ${RHCOS_AMI} || ${RHCOS_AMI} == "null" ]]; then
  capi_log "ERROR: no RHCOS AMI for ${AWS_REGION} in the installer's stream metadata"
  exit 1
fi
capi_log "Using RHCOS AMI ${RHCOS_AMI} in ${AWS_REGION}"

# Everything in the Cluster API tree is named by infrastructure ID, so the
# resource tags, the load balancer names and the subnet names all agree with
# what the installed cluster calls itself.
SUBST_INPUTS=(
  "${INSTALL_DIR}/external-install/cluster.yaml"
  "${INSTALL_DIR}"/external-install/machines/*.yaml
)
sed -i \
  -e "s/CLUSTER_ID/${INFRA_ID}/g" \
  -e "s/ami-REPLACE/${RHCOS_AMI}/g" \
  -e "s/us-east-1/${AWS_REGION}/g" \
  "${SUBST_INPUTS[@]}"

capi_assert_no_placeholders 'CLUSTER_ID|ami-REPLACE' "${SUBST_INPUTS[@]}"

cp -v "${INSTALL_DIR}/external-install/cluster.yaml" "${ARTIFACT_DIR}/capi-cluster.yaml"

# --- phase two: create cluster

if [[ ${PLATFORM_EXTERNAL_CAPI_INFRA_ONLY} == "true" ]]; then
  capi_log "OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY: stopping at infrastructureReady"
  export OPENSHIFT_INSTALL_INFRASTRUCTURE_ONLY=true
fi

# Recorded for the destroy step, which has to stage the same provider build
# and read the same install directory.
cp -v "${INSTALL_DIR}/install-config.yaml" "${SHARED_DIR}/install-config-used.yaml" 2>/dev/null || true

capi_log "Phase 2: create cluster"
set +o errexit
openshift-install create cluster --log-level=debug --dir="${INSTALL_DIR}" &
wait "$!"
ret=$?
set -o errexit

# The installer writes metadata.json during `create cluster`; the destroy step
# needs it whether or not the install succeeded, and it carries no credential.
cp -v "${INSTALL_DIR}/metadata.json" "${SHARED_DIR}/metadata.json" 2>/dev/null || true
cp -v "${INSTALL_DIR}/.openshift_install.log" "${ARTIFACT_DIR}/openshift_install.log" 2>/dev/null || true
if [[ -f "${INSTALL_DIR}/auth/kubeconfig" ]]; then
  cp -v "${INSTALL_DIR}/auth/kubeconfig" "${SHARED_DIR}/kubeconfig"
fi
# The whole install directory is a credential store -- TLS and CA private
# keys, the pull secret, the kubeadmin hash. Only the three files above leave
# this pod, and the Cluster API manifests are copied for diagnosis because the
# installer's own Secrets are not among them.
#
# `*ecret*` catches both the lowercase kind in a filename and the capitalised
# Kind the installer uses when it names a file after the object. This is the
# same exclusion `destroy cluster` applies to .clusterapi_output.
tar -czf "${ARTIFACT_DIR}/capi-manifests.tar.gz" \
  -C "${INSTALL_DIR}" --exclude='*ecret*' \
  .clusterapi_output 2>/dev/null || true

exit "${ret}"
