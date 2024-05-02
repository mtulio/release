#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if [[ ! -f  "${SHARED_DIR}/install-env" ]];
then
    echo "#> WARNING: missing script ${SHARED_DIR}/install-env created by step provider-certification-tool-conf-setup. Skipping opct-destroy"
    exit 0
fi

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

# Run destroy command
${OPCT_EXEC} destroy
