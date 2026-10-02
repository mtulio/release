#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# install-config.yaml for a platform: external install driven by a
# user-supplied Cluster API infrastructure provider.
#

source "${SHARED_DIR}/init-fn.sh"
source "${SHARED_DIR}/capi-fn.sh"

: "${PLATFORM_EXTERNAL_CAPI_EXAMPLE:?set it to an example directory name, e.g. aws-capa}"
: "${PLATFORM_EXTERNAL_CAPI_ARTIFACTS:?set it to the provider artifact directory}"

install_yq4

CONFIG="${SHARED_DIR}/install-config.yaml"
EXAMPLE_DIR=$(capi_example_dir "${PLATFORM_EXTERNAL_CAPI_EXAMPLE}")

# Append the CI registry credentials to the pull secret. openshift-tests and
# any step that pulls a CI image authenticate with this file.
cp -v "${CLUSTER_PROFILE_DIR}/pull-secret" "${REGISTRY_AUTH_FILE}"
if [[ $(dirname "$(dirname "${RELEASE_IMAGE_LATEST}")") != "quay.io" ]]; then
  capi_log "Logging in to the CI registry"
  oc registry login --to "${REGISTRY_AUTH_FILE}"
fi

if [[ -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  CLUSTER_BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/baseDomain")
elif [[ -r "${CLUSTER_PROFILE_DIR}/dns-zone" ]]; then
  CLUSTER_BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/dns-zone")
else
  CLUSTER_BASE_DOMAIN="${BASE_DOMAIN:?no baseDomain in the cluster profile and none set}"
fi

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/CLUSTER_NAME"
echo "${CLUSTER_BASE_DOMAIN}" > "${SHARED_DIR}/BASE_DOMAIN"

capi_log "Cluster ${CLUSTER_NAME}.${CLUSTER_BASE_DOMAIN} from example ${PLATFORM_EXTERNAL_CAPI_EXAMPLE}"

# The example's install-config is the base, not a patch target. See the ref
# documentation for why that direction is the deliberate one.
cp -v "${EXAMPLE_DIR}/install-config.yaml" "${CONFIG}"

# The artifact directory is stated in two places -- here and in the example's
# clusterAPI block -- and they are the same fact. Assert rather than rewrite:
# rewriting would hide an example that had been changed to point somewhere
# else, which is precisely the regression a presubmit exists to catch.
for field in binaryPath componentsPath; do
  value=$(yq4 ".platform.external.clusterAPI.${field}" "${CONFIG}")
  if [[ ${value} != "${PLATFORM_EXTERNAL_CAPI_ARTIFACTS}/"* ]]; then
    capi_log "ERROR: the example's ${field} is ${value}, which is not under"
    capi_log "       PLATFORM_EXTERNAL_CAPI_ARTIFACTS=${PLATFORM_EXTERNAL_CAPI_ARTIFACTS}."
    capi_log "       Either the example moved its artifacts or this job's env is stale."
    exit 1
  fi
done

# Overriding by assignment rather than by merge. A merge would have to be
# ordered against the example's own keys, and `yq eval-all ... *+` silently
# appends to sequences -- which on compute[] would produce two worker pools.
# Not every cluster profile carries an SSH key. The AWS profiles do; the OCI
# ones are built for the agent-based jobs and do not, and a step that assumed
# otherwise would fail an OCI run for a reason that has nothing to do with the
# provider under test. Generate a throwaway pair in that case and keep the
# private half in ${SHARED_DIR}, which is Secret-backed, so a gather step can
# still reach a node.
if [[ -r "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  SSH_PUBLIC_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
else
  capi_log "No ssh-publickey in the cluster profile; generating an ephemeral pair"
  ssh-keygen -t ed25519 -N '' -C "${CLUSTER_NAME}" -f "${SHARED_DIR}/ssh-privatekey" >/dev/null
  chmod 0600 "${SHARED_DIR}/ssh-privatekey"
  SSH_PUBLIC_KEY=$(<"${SHARED_DIR}/ssh-privatekey.pub")
fi
PULL_SECRET=$(awk -v ORS= -v OFS= '{$1=$1}1' "${REGISTRY_AUTH_FILE}")

export CLUSTER_NAME CLUSTER_BASE_DOMAIN SSH_PUBLIC_KEY PULL_SECRET \
       CONTROL_PLANE_REPLICAS COMPUTE_REPLICAS

yq4 --inplace '
  .metadata.name = strenv(CLUSTER_NAME) |
  .baseDomain = strenv(CLUSTER_BASE_DOMAIN) |
  .sshKey = strenv(SSH_PUBLIC_KEY) |
  .pullSecret = strenv(PULL_SECRET) |
  .controlPlane.replicas = (strenv(CONTROL_PLANE_REPLICAS) | tonumber) |
  .compute[0].replicas = (strenv(COMPUTE_REPLICAS) | tonumber)
' "${CONFIG}"

# Verify by the shape of what should no longer be there, never by the presence
# of the new value. An edit that lands fully and one that half-lands look
# identical from the replacement's side; the placeholders are what must be
# gone.
if grep -qE '^(pullSecret|sshKey): *""$' "${CONFIG}"; then
  capi_log "ERROR: a credential placeholder survived in install-config.yaml"
  exit 1
fi
if grep -q 'CHANGE-ME' "${CONFIG}"; then
  capi_log "ERROR: a CHANGE-ME placeholder survived in install-config.yaml"
  exit 1
fi
if [[ $(grep -c "^  name: ${CLUSTER_NAME}$" "${CONFIG}") -ne 1 ]]; then
  capi_log "ERROR: metadata.name is not ${CLUSTER_NAME}"
  exit 1
fi

capi_save_install_config_redacted "${CONFIG}" "${ARTIFACT_DIR}/install-config.yaml"
capi_log "Wrote ${CONFIG} and a redacted copy to the artifact directory"
