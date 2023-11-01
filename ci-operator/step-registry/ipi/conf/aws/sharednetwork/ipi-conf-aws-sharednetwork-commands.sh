#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

declare -x CLUSTER_NAME
declare -x VPC_ID
declare -x STACK_NAME_VPC
declare -x STACK_NAME_CAGW
declare -x STACK_NAME_SUBNETS
declare -x TEMPLATE_BASE_URL

function join_by { local IFS="$1"; shift; echo "$*"; }

function show() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function wait_for_stack() {
  stack_name=$1

  show "Waiting for stack create stack complete: ${stack_name}"
  aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${stack_name}" &
  wait "$!"
  show "Waited for stack ${stack_name}"

  stack_status=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name}" | jq -r .Stacks[0].StackStatus)
  if [[ "$stack_status" != "CREATE_COMPLETE" ]]; then
    show "Detected Failed Stack deployment with status: [${stack_status}]"
    exit 1
  fi
}

function create_stack_localzone() {
  echo "Downloading CloudFormation template for Local Zone subnet"
  template_path="/tmp/01.99_net_local-zone.yaml"
  curl -L https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation/01.99_net_local-zone.yaml -o $template_path

  # Randomly select the Local Zone in the Region (to increase coverage of tested zones added automatically)
  localzone_name=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  echo "Local Zone selected: ${localzone_name}"

  vpc_rtb_pub=$(aws --region $REGION cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue')
  echo "VPC info: ${VPC_ID} [public route table=${vpc_rtb_pub}]"

  stack_name_localzone="${CLUSTER_NAME}-${localzone_name}"
  aws --region "${REGION}" cloudformation create-stack \
    --stack-name "${stack_name_localzone}" \
    --template-body file://$template_path \
    --tags "${TAGS}" \
    --parameters \
      ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
      ParameterKey=PublicRouteTableId,ParameterValue="${vpc_rtb_pub}" \
      ParameterKey=SubnetName,ParameterValue="${CLUSTER_NAME}-public-${localzone_name}" \
      ParameterKey=ZoneName,ParameterValue="${localzone_name}" \
      ParameterKey=PublicSubnetCidr,ParameterValue="10.0.128.0/20" &

  wait "$!"
  echo "Created stack ${stack_name_localzone}"

  echo "Created stack: ${stack_name_localzone}"
  wait_for_stack "${stack_name_localzone}"

  subnet_lz=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${stack_name_localzone}" | jq -r .Stacks[0].Outputs[0].OutputValue)
  subnets_arr=$(jq -c ". + [\"$subnet_lz\"]" <(echo "$subnets_arr"))
  echo "Subnets (including local zones): ${subnets_arr}"

  echo "${stack_name_localzone}" >> "${SHARED_DIR}/sharednetwork_stackname_localzone"
}

function create_stack_carrier_gateway() {

  template_file="01.01_carrier_gateway.yaml"
  template_path="/tmp/${template_file}"
  template_url="${TEMPLATE_BASE_URL}"/"${template_file}"

  show "Downloading CloudFormation template to setup Carrier Gateway (CAGW) from ${template_url}"
  curl -sL "${template_url}" -o $template_path

  show "Creating CAGW template"
  STACK_NAME_CAGW=${CLUSTER_NAME}-cagw
  aws cloudformation create-stack \
    --region "${REGION}" \
    --stack-name "${STACK_NAME_CAGW}" \
    --template-body file://$template_path \
    --parameters \
      ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
      ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}"

  show "Waiting for creation complete"
  wait_for_stack "${STACK_NAME_CAGW}"

  echo "${STACK_NAME_CAGW}" >> "${SHARED_DIR}/sharednetwork_stackname_edge_cagw"
}

function create_stack_edge_subnets() {

  template_file="01.99_subnet.yaml"
  template_path="/tmp/${template_file}"
  template_url="${TEMPLATE_BASE_URL}"/"${template_file}"

  show "Downloading CloudFormation template to create Public and Private subnets from ${template_url}"
  curl -sL "${template_url}" -o $template_path

  edge_zone_name=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  show "Edge Zone selected: ${edge_zone_name}"

  vpc_rtb_pub=$(aws --region "$REGION" cloudformation describe-stacks \
    --stack-name "${STACK_NAME_CAGW}" \
    | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="PublicRouteTableId").OutputValue' )

  #> Select the first route table from the list
  vpc_rtb_priv=$(aws --region "$REGION" cloudformation describe-stacks \
    --stack-name "${STACK_NAME_VPC}" \
    | jq -r '.Stacks[0].Outputs[]
      | select(.OutputKey=="PrivateRouteTableIds").OutputValue
      | split(",")[0] | split("=")[1]' \
  )

  subnet_cidr_pub="10.0.128.0/24"
  subnet_cidr_priv="10.0.129.0/24"

  cat <<EOF
REGION=$REGION
VPC_ID=$VPC_ID
edge_zone_name=$edge_zone_name
vpc_rtb_pub=$vpc_rtb_pub
vpc_rtb_priv=$vpc_rtb_priv
subnet_cidr_pub=$subnet_cidr_pub
subnet_cidr_priv=$subnet_cidr_priv
EOF

  STACK_NAME_SUBNETS=${CLUSTER_NAME}-subnets-${edge_zone_name/${REGION}-/}
  show "Creating stack: ${STACK_NAME_SUBNETS}"
  aws cloudformation create-stack \
    --region "${REGION}" \
    --stack-name "${STACK_NAME_SUBNETS}" \
    --template-body file://$template_path \
    --parameters \
      ParameterKey=VpcId,ParameterValue="${VPC_ID}" \
      ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}" \
      ParameterKey=ZoneName,ParameterValue="${edge_zone_name}" \
      ParameterKey=PublicRouteTableId,ParameterValue="${vpc_rtb_pub}" \
      ParameterKey=PublicSubnetCidr,ParameterValue="${subnet_cidr_pub}" \
      ParameterKey=PrivateRouteTableId,ParameterValue="${vpc_rtb_priv}" \
      ParameterKey=PrivateSubnetCidr,ParameterValue="${subnet_cidr_priv}"

  show "Created stack: ${STACK_NAME_SUBNETS}"
  wait_for_stack "${STACK_NAME_SUBNETS}"

  subnet_edge=$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_SUBNETS}" --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnetId'].OutputValue" --output text | tr ',' '\n')
  subnets_arr=$(jq -c ". + [\"$subnet_edge\"]" <(echo "$subnets_arr"))
  show "Subnets (including edge zones): ${subnets_arr}"

  echo "${STACK_NAME_SUBNETS}" >> "${SHARED_DIR}/sharednetwork_stackname_edge_subnets"
}

if [[ "${EDGE_ZONE_TYPE-}" == "wavelength-zone" ]]; then
  # TODO(mtulio/mrbraga): should use installer@main once the PR is merged:
  # https://github.com/openshift/installer/pull/7652
  TEMPLATE_BASE_URL="https://raw.githubusercontent.com/mtulio/installer/edge-aws-wavelength-zone-byovpc/upi/aws/cloudformation"
else
  TEMPLATE_BASE_URL="https://raw.githubusercontent.com/openshift/installer/master/upi/aws/cloudformation"
fi

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
TAGS="Key=expirationDate,Value=${EXPIRATION_DATE}"

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-sharednetwork.yaml.patch

REGION="${LEASED_RESOURCE}"

CLUSTER_NAME="$(yq-go r "${CONFIG}" 'metadata.name')"

curl -L "${TEMPLATE_BASE_URL}"/01_vpc.yaml -o /tmp/01_vpc.yaml

# The above cloudformation template's max zones account is 3
if [[ "${ZONES_COUNT}" -gt 3 ]]
then
  ZONES_COUNT=3
fi

STACK_NAME_VPC="${CLUSTER_NAME}-shared-vpc"
aws --region "${REGION}" cloudformation create-stack \
  --stack-name "${STACK_NAME_VPC}" \
  --template-body "$(cat /tmp/01_vpc.yaml)" \
  --tags "${TAGS}" \
  --parameters "ParameterKey=AvailabilityZoneCount,ParameterValue=${ZONES_COUNT}" &

wait "$!"
echo "Created stack"

aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME_VPC}" &
wait "$!"
echo "Waited for stack"

subnets_arr="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -c '[.Stacks[].Outputs[] | select(.OutputKey | endswith("SubnetIds")).OutputValue | split(",")[]]')"
echo "Subnets : ${subnets_arr}"

subnets=[]

# save stack information to ${SHARED_DIR} for deprovision step
echo "${STACK_NAME_VPC}" >> "${SHARED_DIR}/sharednetworkstackname"

VPC_ID=$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME_VPC}" | jq -r '.Stacks[0].Outputs[] | select(.OutputKey=="VpcId").OutputValue')
echo "$VPC_ID" > "${SHARED_DIR}/vpc_id"

# Create network requirements for edge zones.
if [[ -n "${AWS_EDGE_POOL_ENABLED-}" ]]; then
  if [[ "${EDGE_ZONE_TYPE-}" == "wavelength-zone" ]]; then
    create_stack_carrier_gateway
    create_stack_edge_subnets
  else
    # TODO: move to create_stack_edge_subnets, using public subnet.
    create_stack_localzone
  fi
fi

# Converting for a valid format to install-config.yaml
subnets=${subnets_arr//\"/\'}
echo "Subnets config : ${subnets}"

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${REGION}" ec2 describe-availability-zones --filters Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[].ZoneName' | sort -u)
ZONES=("${AVAILABILITY_ZONES[@]:0:${ZONES_COUNT}}")
ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
echo "AWS region: ${REGION} (zones: ${ZONES_STR})"

cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
platform:
  aws:
    subnets: ${subnets}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
