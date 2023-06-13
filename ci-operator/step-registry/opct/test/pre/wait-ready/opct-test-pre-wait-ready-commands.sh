#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Ensure all Cluster Operators are ready
for check in 1 2 3; do
  echo "Waiting for readness...$check/3"
  oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m > /dev/null
  oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
  oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
  sleep 30
done