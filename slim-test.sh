#!/usr/bin/env bash

################################################################################
# SLIM-TEST: Bare-bones IBMi LPAR Clone & Provision
# Purpose: Minimal test script - clone volumes and provision LPAR
################################################################################

# Timestamp logging
timestamp() {
    while IFS= read -r line; do
        printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
    done
}
exec > >(timestamp) 2>&1

set -eu

echo ""
echo "========================================================================"
echo " SLIM-TEST: IBMi LPAR Clone & Provision"
echo "========================================================================"
echo ""

################################################################################
# CONFIGURATION
################################################################################

readonly API_KEY="${IBMCLOUD_API_KEY}"
readonly REGION="us-south"
readonly RESOURCE_GROUP="Default"
readonly PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/db1a8b544a184fd7ac339c243684a9b7:973f4d55-9056-4848-8ed0-4592093161d2::"
readonly CLOUD_INSTANCE_ID="973f4d55-9056-4848-8ed0-4592093161d2"
readonly API_VERSION="2024-02-28"

readonly PRIMARY_LPAR="murphy-prod"
readonly PRIMARY_INSTANCE_ID="fea64706-1929-41c9-a761-68c43a8f29cc"
readonly SECONDARY_LPAR="murphy-prod-clone17"

readonly SUBNET_ID="9b9c414e-aa95-41aa-8ed2-40141e0c42fd"
readonly PRIVATE_IP="192.168.10.17"
readonly PUBLIC_SUBNET_NAME="public-net-$(date +"%Y%m%d%H%M%S")"
readonly KEYPAIR_NAME="murph2"

readonly MEMORY_GB=2
readonly PROCESSORS=0.25
readonly PROC_TYPE="shared"
readonly SYS_TYPE="s1022"
readonly IMAGE_ID="IBMI-EMPTY"
readonly DEPLOYMENT_TYPE="VMNoStorage"

readonly CLONE_PREFIX="murphy-prod-$(date +"%Y%m%d%H%M")"

PRIMARY_BOOT_ID=""
PRIMARY_DATA_IDS=""
CLONE_TASK_ID=""
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
PUBLIC_SUBNET_ID=""
IAM_TOKEN=""
SECONDARY_INSTANCE_ID=""

echo "Config loaded"
echo ""

################################################################################
# STEP 1: AUTHENTICATE & TARGET
################################################################################
echo "→ Step 1: Authenticating to IBM Cloud..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1
ibmcloud target -g "$RESOURCE_GROUP" > /dev/null 2>&1
ibmcloud pi ws target "$PVS_CRN" > /dev/null 2>&1
echo "✓ Authenticated"
echo ""

################################################################################
# STEP 2: IDENTIFY VOLUMES
################################################################################
echo "→ Step 2: Identifying volumes on primary LPAR..."
PRIMARY_VOLUME_DATA=$(ibmcloud pi ins vol ls "$PRIMARY_INSTANCE_ID" --json 2>/dev/null)

PRIMARY_BOOT_ID=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '.volumes[]? | select(.bootVolume == true) | .volumeID' | head -n 1)

set +e
PRIMARY_DATA_IDS=$(echo "$PRIMARY_VOLUME_DATA" | jq -r '.volumes[]? | select(.bootVolume != true) | .volumeID' 2>/dev/null | paste -sd "," - 2>/dev/null)
set -e

if [[ -z "$PRIMARY_DATA_IDS" ]]; then
    PRIMARY_DATA_IDS=""
fi

if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    PRIMARY_VOLUME_IDS="${PRIMARY_BOOT_ID},${PRIMARY_DATA_IDS}"
else
    PRIMARY_VOLUME_IDS="${PRIMARY_BOOT_ID}"
fi

echo "✓ Boot: ${PRIMARY_BOOT_ID}"
echo "✓ Data: ${PRIMARY_DATA_IDS:-None}"
echo ""

################################################################################
# STEP 3: CLONE VOLUMES
################################################################################
echo "→ Step 3: Cloning volumes..."
CLONE_JSON=$(ibmcloud pi volume clone-async create "$CLONE_PREFIX" --volumes "$PRIMARY_VOLUME_IDS" --json)
CLONE_TASK_ID=$(echo "$CLONE_JSON" | jq -r '.cloneTaskID')
echo "✓ Clone started: ${CLONE_TASK_ID}"
echo ""

################################################################################
# STEP 4: CREATE PUBLIC SUBNET
################################################################################
echo "→ Step 4: Creating public subnet..."
PUBLIC_SUBNET_JSON=$(ibmcloud pi subnet create "$PUBLIC_SUBNET_NAME" --net-type public --json 2>/dev/null)
PUBLIC_SUBNET_ID=$(echo "$PUBLIC_SUBNET_JSON" | jq -r '.id // .networkID')
echo "✓ Subnet created: ${PUBLIC_SUBNET_ID}"
echo ""

################################################################################
# STEP 5: CREATE EMPTY LPAR
################################################################################
echo "→ Step 5: Creating empty LPAR..."

# Get IAM token
echo "  Getting IAM token..."
IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    -d "apikey=${API_KEY}")
IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "ERROR: Failed to get IAM token"
    echo "Response: $IAM_RESPONSE"
    exit 1
fi
echo "  IAM token retrieved"

# Build payload
PAYLOAD=$(cat <<EOF
{
  "serverName": "${SECONDARY_LPAR}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "deploymentType": "${DEPLOYMENT_TYPE}",
  "keyPairName": "${KEYPAIR_NAME}",
  "networks": [
    {"networkID": "${SUBNET_ID}", "ipAddress": "${PRIVATE_IP}"},
    {"networkID": "${PUBLIC_SUBNET_ID}"}
  ]
}
EOF
)

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "  Calling PowerVS API..."
RESPONSE=$(curl -s -X POST "${API_URL}" \
    -H "Authorization: Bearer ${IAM_TOKEN}" \
    -H "CRN: ${PVS_CRN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

SECONDARY_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.pvmInstanceID // .[0].pvmInstanceID // .pvmInstance.pvmInstanceID')

if [[ -z "$SECONDARY_INSTANCE_ID" || "$SECONDARY_INSTANCE_ID" == "null" ]]; then
    echo "ERROR: Failed to create LPAR"
    echo "Response: $RESPONSE"
    exit 1
fi
echo "✓ LPAR created: ${SECONDARY_INSTANCE_ID}"
echo ""

# Wait for SHUTOFF
echo "→ Waiting for LPAR to reach SHUTOFF..."
sleep 45
while true; do
    STATUS=$(ibmcloud pi ins get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null | jq -r '.status')
    echo "  Status: ${STATUS}"
    if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "STOPPED" ]]; then
        break
    fi
    sleep 30
done
echo "✓ LPAR is SHUTOFF"
echo ""

################################################################################
# STEP 6: WAIT FOR CLONE & ATTACH VOLUMES
################################################################################
echo "→ Step 6: Waiting for clone to complete..."
while true; do
    STATUS=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json | jq -r '.status')
    echo "  Clone status: ${STATUS}"
    if [[ "$STATUS" == "completed" ]]; then
        break
    fi
    sleep 60
done
echo "✓ Clone completed"
echo ""

# Extract cloned volume IDs
CLONE_RESULT=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json)
CLONE_BOOT_ID=$(echo "$CLONE_RESULT" | jq -r --arg boot "$PRIMARY_BOOT_ID" '.clonedVolumes[] | select(.sourceVolumeID == $boot) | .clonedVolumeID')

if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    CLONE_DATA_IDS=$(echo "$CLONE_RESULT" | jq -r --arg boot "$PRIMARY_BOOT_ID" '.clonedVolumes[] | select(.sourceVolumeID != $boot) | .clonedVolumeID' | paste -sd "," -)
fi

echo "✓ Boot volume clone: ${CLONE_BOOT_ID}"
echo "✓ Data volume clones: ${CLONE_DATA_IDS:-None}"
echo ""

# Wait for volumes to be available
echo "→ Waiting for volumes to be available..."
while true; do
    BOOT_STATUS=$(ibmcloud pi volume get "$CLONE_BOOT_ID" --json | jq -r '.state | ascii_downcase')
    if [[ "$BOOT_STATUS" == "available" ]]; then
        break
    fi
    sleep 30
done
echo "✓ Volumes available"
echo ""

# Attach boot volume
echo "→ Attaching boot volume..."
ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" --volumes "$CLONE_BOOT_ID" >/dev/null 2>&1
sleep 60

# Wait for boot volume to appear
while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null | jq -r '(.volumes // [])[]?.volumeID')
    if grep -qx "$CLONE_BOOT_ID" <<<"$VOL_LIST"; then
        break
    fi
    sleep 30
done
echo "✓ Boot volume attached"

# Mark as bootable
ibmcloud pi volume update "$CLONE_BOOT_ID" --bootable >/dev/null 2>&1
echo "✓ Boot volume marked as bootable"
echo ""

# Attach data volumes if any
if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "→ Attaching data volumes..."
    IFS=',' read -ra DATA_VOL_ARRAY <<<"$CLONE_DATA_IDS"
    for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
        ibmcloud pi instance volume attach "$SECONDARY_INSTANCE_ID" --volumes "$DATA_VOL_ID" >/dev/null 2>&1
        sleep 30
        while true; do
            VOL_LIST=$(ibmcloud pi instance volume list "$SECONDARY_INSTANCE_ID" --json 2>/dev/null | jq -r '(.volumes // [])[]?.volumeID')
            if grep -qx "$DATA_VOL_ID" <<<"$VOL_LIST"; then
                break
            fi
            sleep 30
        done
    done
    echo "✓ Data volumes attached"
    echo ""
fi

################################################################################
# STEP 7: VERIFY ATTACHMENTS
################################################################################
echo "→ Step 7: Verifying all volumes attached..."
sleep 120
echo "✓ Volumes confirmed"
echo ""

################################################################################
# STEP 8: CONFIGURE BOOT MODE
################################################################################
echo "→ Step 8: Configuring boot mode (NORMAL, Disk B)..."
ibmcloud pi instance operation "$SECONDARY_INSTANCE_ID" --operation-type boot --boot-mode b --boot-operating-mode normal >/dev/null 2>&1
sleep 60
echo "✓ Boot mode configured"
echo ""

################################################################################
# STEP 9: START LPAR
################################################################################
echo "→ Step 9: Starting LPAR..."
ibmcloud pi instance action "$SECONDARY_INSTANCE_ID" --operation start >/dev/null 2>&1
echo "✓ Start command sent"
echo ""

################################################################################
# STEP 10: WAIT FOR ACTIVE
################################################################################
echo "→ Step 10: Waiting for LPAR to reach ACTIVE..."
while true; do
    STATUS=$(ibmcloud pi instance get "$SECONDARY_INSTANCE_ID" --json 2>/dev/null | jq -r '.status')
    echo "  Status: ${STATUS}"
    if [[ "$STATUS" == "ACTIVE" ]]; then
        break
    fi
    sleep 60
done
echo "✓ LPAR is ACTIVE"
echo ""

echo "========================================================================"
echo " TEST COMPLETE"
echo "========================================================================"
echo ""

exit 0

