#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TEMP until figure out issues in deployment when declaring release:initial in workflow
if [[ -n "${PLATFORM_EXTERNAL_OVERRIDE_RELEASE-}" ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PLATFORM_EXTERNAL_OVERRIDE_RELEASE}"
fi
echo "Using release image ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

STEP_WORKDIR=${STEP_WORKDIR:-/tmp}
INSTALL_DIR=${STEP_WORKDIR}/install-dir
mkdir -vp "${INSTALL_DIR}"

source "${SHARED_DIR}/init-fn.sh" || true

log "Copying to install dir"
cp -vp "${SHARED_DIR}"/install-config.yaml "${INSTALL_DIR}"/install-config.yaml

log "Creating manifests"
openshift-install create manifests --dir "${INSTALL_DIR}"

log "\n
#
# << Manifest customization >>
#"

#
# MachineConfig for kubelet providerId
#
function create_machineconfig_kubelet() {
    local node_role=$1
    # shellcheck disable=SC1039
    cat << EOF > "$STEP_WORKDIR/mc-kubelet-${node_role}.bu"
variant: openshift
version: 4.13.0
metadata:
  name: 00-$node_role-kubelet-providerid
  labels:
    machineconfiguration.openshift.io/role: $node_role
storage:
  files:
  - mode: 0755
    path: "/usr/local/bin/kubelet-providerid"
    contents:
      inline: |
        #!/bin/bash
        set -e -o pipefail
        NODECONF=/etc/systemd/system/kubelet.service.d/20-providerid.conf
        if [ -e "\${NODECONF}" ]; then
            echo "Not replacing existing \${NODECONF}"
            exit 0
        fi

        PROVIDER_ID=${PROVIDER_ID_COMMAND}

        if [[ -z "\${PROVIDER_ID}" ]]; then
            echo "Can not obtain provider-id from the metadata service."
            exit 1
        fi 

        cat > "\${NODECONF}" <<EOF
        [Service]
        Environment="KUBELET_PROVIDERID=\${PROVIDER_ID}"
        EOF
systemd:
  units:
  - name: kubelet-providerid.service
    enabled: true
    contents: |
      [Unit]
      Description=Fetch kubelet provider id from Metadata
      After=NetworkManager-wait-online.service
      Before=kubelet.service
      [Service]
      ExecStart=/usr/local/bin/kubelet-providerid
      Type=oneshot
      [Install]
      WantedBy=network-online.target
EOF
}

function process_butane() {
  install_butane
  local src_file=$1; shift
  local dest_file=$1

  butane "$src_file" -o "$dest_file"
}

if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" == "yes" ]]; then
  echo "Creating MachineConfig for Provider ID"
  case $PROVIDER_NAME in
      "aws") PROVIDER_ID_COMMAND="aws:///\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/placement/availability-zone)/\$(curl -fSs http://169.254.169.254/2022-09-24/meta-data/instance-id)" ;;
      "oci") PROVIDER_ID_COMMAND="\$(curl -H \"Authorization: Bearer Oracle\" -sL http://169.254.169.254/opc/v2/instance/ | jq -r .id)" ;;
      *) echo "Unkonwn Provider: ${PROVIDER_NAME}"; exit 1;;
  esac

  create_machineconfig_kubelet "master"
  create_machineconfig_kubelet "worker"

  process_butane "$STEP_WORKDIR/mc-kubelet-master.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-master-kubelet-providerid.yaml"
  process_butane "$STEP_WORKDIR/mc-kubelet-worker.bu" "${INSTALL_DIR}/openshift/99_openshift-machineconfig_00-worker-kubelet-providerid.yaml"

  # yq4 ea -i '.status.platformStatus.external.cloudControllerManager.state="External"' \
  #   "${INSTALL_DIR}"/manifests/cluster-infrastructure-02-config.yml

  cp -vf "${INSTALL_DIR}"/openshift/99_openshift-machineconfig_00-*-kubelet-providerid.yaml ${ARTIFACT_DIR}/
fi

#
# Save infrastructure to shared dir
#

cp -vf "${INSTALL_DIR}"/manifests/cluster-infrastructure-02-config.yml "${ARTIFACT_DIR}"/cluster-infrastructure-02-config.yml

#
# Clean up MAPI manifests
#

### Remove control plane machines and CPMS
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_master-machines-*.yaml
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml

### Remove compute machinesets (optional)
rm -vf "${INSTALL_DIR}"/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

log "\n#
# << Ignition config/generation >>
#"

openshift-install --dir="${INSTALL_DIR}" create ignition-configs &
wait "$!"

log "\n# << Saving to shared dir >>#"

# cp -vf "${INSTALL_DIR}"/*.ign "${SHARED_DIR}"/
# cp -vf "${INSTALL_DIR}"/auth/* "${SHARED_DIR}"/
# cp -rvf "${INSTALL_DIR}"/auth "${SHARED_DIR}"/
# cp -vf "${INSTALL_DIR}"/metadata.json "${SHARED_DIR}"/

cp -vt "${SHARED_DIR}" \
  "${dir}"/auth/* \
  "${dir}/metadata.json" \
  "${dir}"/*.ign
