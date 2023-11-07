#!/bin/bash

#
# Select random AWS Local and/or Wavelength Zone, opt-in the zone group (when opted-out),
# saving the zone name to be used in install-config.yaml.
#

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export REGION="${LEASED_RESOURCE}"

declare -x ZONES_LIMIT=${EDGE_ZONES_LIMIT:-1}
mapfile -t ZONE_TYPES_ARR < <(echo "${EDGE_ZONE_TYPES-}"  | tr ',' '\n')

truncate -s 0 "${SHARED_DIR}/edge-zones.txt"

function show() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

# select_edge_zones_by_type select one or more zones from a given type,
# saving it in a control file to be used later.
function select_edge_zones_by_type() {
    local zone_type
    zone_type=$1; shift

    show "select_edge_zones_by_type() $zone_type"
    aws --region "$REGION" ec2 describe-availability-zones \
        --all-availability-zones \
        --filter Name=state,Values=available Name=zone-type,Values="${zone_type}" \
        | jq -r '.AvailabilityZones[].ZoneName' \
        | shuf | tail -n "${ZONES_LIMIT}" > "${SHARED_DIR}/edge-zones_${zone_type}.txt"
}

# select_edge_zones interacts over the zone types, calling the zone selector.
function select_edge_zones() {
    show "select_edge_zones() COUNT=${#ZONE_TYPES_ARR[*]}"
    for zone_type in "${ZONE_TYPES_ARR[@]}" ; do
        show "select_edge_zones() selected=${zone_type}"
        select_edge_zones_by_type "$zone_type"
    done
}

# opt_into_zone opt-into a zone group, waiting the given zone name changed the status to
# opted-int, saving the zone_name to be used in the later steps. When timed out, exit with error.
opt_into_zone() {
    local zone_group
    local zone_name
    zone_group=$1; shift
    zone_name=$2

    aws --region "$REGION" ec2 modify-availability-zone-group --group-name "${zone_group}" --opt-in-status opted-in
    show "Zone group ${zone_group} opt-in status modified"

    count=0
    while true; do
        if aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
            --filters Name=zone-name,Values="$zone_name" \
            | jq -r '.AvailabilityZones[]' == "opted-in"; then
            break;
        fi
        if [ $count -ge 10 ]; then
            show "Timeout waiting for zone ${zone_name} attribute OptInStatus==opted-in"
            exit 1
        fi
        count=$((count+1))
        show "Waiting OptInStatus with value opted-in [$count/10]"
        sleep 30
    done
    echo "Zone group ${zone_group} opted-in."
    echo -e "$zone_name" >> "${SHARED_DIR}/edge-zones.txt"
}

optin_zone_check() {
    local zone_name
    local zone_group
    zone_name=$1; shift

    show "opt_into_zone() zone_name=${zone_name}"
    zone_group=$(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
        --filters Name=zone-name,Values="$zone_name" \
        --query "AvailabilityZones[].GroupName" --output text)

    show "opt_into_zone() zone_group=${zone_group}"
    if [[ $(aws --region "$REGION" ec2 describe-availability-zones --all-availability-zones \
        --filters Name=zone-name,Values="$zone_name" \
        --query 'AvailabilityZones[].OptInStatus' --output text) == "opted-in" ]];
    then
        echo "Zone group ${zone_group} already opted-in"
        echo -e "$zone_name" >> "${SHARED_DIR}/edge-zones.txt"
        return
    fi
    opt_into_zone "$zone_group" "$zone_name"
}

optin_zones() {
    show "optin_zones() COUNT=${#ZONE_TYPES_ARR[*]}"
    for zone_type in "${ZONE_TYPES_ARR[@]}" ; do
        while read -r zone_name; do
            show "optin_zones() zone_group=${zone_type} zone_name=${zone_name}"
            optin_zone_check "$zone_name"
        done < "$SHARED_DIR"/edge-zones_"${zone_type}".txt
    done
}

# check_zone_offerings checks if the zone have one or more instances available, otherwise
# another zone must be selected.
check_zone_offerings() {
    while read -r zone_name; do
        show "check_zone_offerings() zone_name=${zone_name}"
        output_file="$SHARED_DIR"/zone-ec2-offerings_"${zone_name}".txt
        aws ec2 describe-instance-type-offerings --region "${REGION}" \
            --location-type availability-zone \
            --filters Name=location,Values="${zone_name}" \
            --query 'InstanceTypeOfferings[].InstanceType[]' \
            --output json | jq -r .[] \
            > "${output_file}"
        cat "${output_file}"
        if [[ ! -s "${output_file}" ]]; then
            show "ERROR: the following zone does not offer any EC2 instances: ${zone_name} [${output_file}]"
            # TODO: create 'fallback': replace or remove the zone
        fi
    done < "${SHARED_DIR}/edge-zones.txt"
}

select_edge_zones;
optin_zones;
check_zone_offerings;