#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#
# Approve pending kubelet CSRs. See the ref documentation for why there is
# nothing on `platform: external` that does this by itself.
#

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ ! -s ${KUBECONFIG} ]]; then
  echo "No kubeconfig in ${SHARED_DIR}; the install did not get far enough."
  exit 0
fi

deadline=$(( $(date +%s) + $(
  case "${PLATFORM_EXTERNAL_CAPI_CSR_TIMEOUT}" in
  *m) echo $(( ${PLATFORM_EXTERNAL_CAPI_CSR_TIMEOUT%m} * 60 )) ;;
  *h) echo $(( ${PLATFORM_EXTERNAL_CAPI_CSR_TIMEOUT%h} * 3600 )) ;;
  *s) echo "${PLATFORM_EXTERNAL_CAPI_CSR_TIMEOUT%s}" ;;
  *) echo "${PLATFORM_EXTERNAL_CAPI_CSR_TIMEOUT}" ;;
  esac
) ))

expected=${PLATFORM_EXTERNAL_CAPI_EXPECTED_NODES}
approved_total=0

while [[ $(date +%s) -lt ${deadline} ]]; do
  # A CSR with no .status.certificate has not been signed. Selecting on the
  # absence of the field rather than on a condition is deliberate: a request
  # that was denied also has conditions, and re-approving it is pointless.
  pending=$(oc get csr -o json 2>/dev/null |
    jq -r '.items[] | select(.status | has("certificate") | not) | .metadata.name' 2>/dev/null || true)

  if [[ -n ${pending} ]]; then
    # shellcheck disable=SC2086
    # Unquoted on purpose: this is a list of names to pass as separate
    # arguments, and quoting the word would pass one argument containing
    # newlines.
    if oc adm certificate approve ${pending} >/dev/null 2>&1; then
      count=$(wc -w <<<"${pending}")
      approved_total=$(( approved_total + count ))
      echo "$(date -u --rfc-3339=seconds) - approved ${count} CSR(s), ${approved_total} in total"
    fi
  fi

  if [[ ${expected} -gt 0 ]]; then
    ready=$(oc get nodes -o json 2>/dev/null |
      jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo 0)
    if [[ ${ready} -ge ${expected} ]]; then
      echo "${ready} node(s) Ready, at or above the expected ${expected}."
      break
    fi
  fi

  sleep 20
done

oc get nodes -o wide > "${ARTIFACT_DIR}/nodes.txt" 2>&1 || true
oc get csr > "${ARTIFACT_DIR}/csr.txt" 2>&1 || true

# Never fail the job from here. This step is a workaround for a missing
# product capability; if nodes did not come Ready the cause is upstream of it
# and the wait steps that follow are where that should be reported, with their
# own diagnostics, rather than here as "CSR approval failed".
echo "Done. Approved ${approved_total} CSR(s)."
