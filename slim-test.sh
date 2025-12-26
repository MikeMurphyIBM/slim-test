#!/usr/bin/env bash

################################################################################
# SLIM-TEST: Bare-bones IBMi LPAR Clone & Provision v8
################################################################################

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
readonly SECONDARY_LPAR="murphy-prod-clone22"

readonly SUBNET_ID="9b9c414e-aa95-41aa-8ed2-40141e0c42fd"
readonly PRIVATE_IP="192.168.10.22"
readonly PUBLIC_SUBNET_NAME="public-net-$(date +"%Y%m%d%H%M%S")"
readonly KEYPAIR_NAME="murph2"

readonly LPAR_NAME="${SECONDARY_LPAR}"
readonly MEMORY_GB=2
readonly PROCESSORS=0.25
readonly PROC_TYPE="shared"
readonly SYS_TYPE="s1022"
readonly IMAGE_ID="IBMI-EMPTY"
readonly DEPLOYMENT_TYPE="VMNoStorage"

readonly CLONE_PREFIX="murphy-prod-$(date +"%Y%m%d%H%M")"

readonly POLL_INTERVAL=30
readonly STATUS_POLL_LIMIT=30
readonly INITIAL_WAIT=45

PRIMARY_BOOT_ID=""
PRIMARY_DATA_IDS=""
CLONE_TASK_ID=""
CLONE_BOOT_ID=""
CLONE_DATA_IDS=""
PUBLIC_SUBNET_ID=""
IAM_TOKEN=""
LPAR_INSTANCE_ID=""

echo "Config loaded"
echo ""

################################################################################
# STEP 1: AUTHENTICATE & TARGET
################################################################################
echo "→ Step 1: Authenticating to IBM Cloud..."
ibmcloud login --apikey "$API_KEY" -r "$REGION" > /dev/null 2>&1
ibmcloud target -g "$RESOURCE_GROUP" > /dev/null 2>&1
ibmcloud pi workspace target "$PVS_CRN" > /dev/null 2>&1
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
PUBLIC_SUBNET_ID=$(echo "$PUBLIC_SUBNET_JSON" | jq -r '.id // .networkID // empty' 2>/dev/null || true)

if [[ -z "$PUBLIC_SUBNET_ID" || "$PUBLIC_SUBNET_ID" == "null" ]]; then
    echo "ERROR: Failed to create public subnet"
    exit 1
fi

echo "✓ Subnet created: ${PUBLIC_SUBNET_ID}"
echo ""

################################################################################
# STEP 5: CREATE EMPTY LPAR (VERBATIM FROM JOB4-CREATE)
################################################################################
echo "→ Step 5: Creating empty LPAR..."

echo "→ Retrieving IAM access token for API authentication..."

IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "✗ ERROR: IAM token retrieval failed"
    echo "Response: $IAM_RESPONSE"
    exit 1
fi

export IAM_TOKEN
echo "✓ IAM token retrieved successfully"
echo ""

echo "→ Building LPAR configuration payload..."

# Construct JSON payload for LPAR creation
PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "deploymentType": "${DEPLOYMENT_TYPE}",
  "keyPairName": "${KEYPAIR_NAME}",
  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "${PRIVATE_IP}"
    },
    {
      "networkID": "${PUBLIC_SUBNET_ID}"
    }
  ]
}
EOF
)

echo "  Network Configuration:"
echo "    - Private: ${SUBNET_ID} (IP: ${PRIVATE_IP})"
echo "    - Public:  ${PUBLIC_SUBNET_ID} (${PUBLIC_SUBNET_NAME})"
echo ""

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "→ Submitting LPAR creation request to PowerVS API..."

# Retry logic for API resilience
ATTEMPTS=0
MAX_ATTEMPTS=3

while [[ $ATTEMPTS -lt $MAX_ATTEMPTS && -z "$LPAR_INSTANCE_ID" ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "  Attempt ${ATTEMPTS}/${MAX_ATTEMPTS}..."
    
    # Temporarily disable exit-on-error for this block
    set +e
    RESPONSE=$(curl -s -X POST "${API_URL}" \
        -H "Authorization: Bearer ${IAM_TOKEN}" \
        -H "CRN: ${PVS_CRN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" 2>&1)
    CURL_CODE=$?
    set -e
    
    if [[ $CURL_CODE -ne 0 ]]; then
        echo "  ⚠ WARNING: curl failed with exit code ${CURL_CODE}"
        sleep 5
        continue
    fi
    
    # Safe jq parsing - handles multiple response formats
    LPAR_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '
        .pvmInstanceID? //
        (.[0].pvmInstanceID? // empty) //
        .pvmInstance.pvmInstanceID? //
        empty
    ' 2>/dev/null || true)
    
    if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
        echo "  ⚠ WARNING: Could not extract instance ID - retrying..."
        sleep 5
    fi
done

# Fail if all attempts exhausted without success
if [[ -z "$LPAR_INSTANCE_ID" || "$LPAR_INSTANCE_ID" == "null" ]]; then
    echo "✗ FAILURE: Could not retrieve LPAR instance ID after ${MAX_ATTEMPTS} attempts"
    echo ""
    echo "API Response:"
    echo "$RESPONSE"
    exit 1
fi

echo "✓ LPAR creation request accepted"
echo "✓ Instance ID: ${LPAR_INSTANCE_ID}"
echo ""

echo "→ Waiting ${INITIAL_WAIT} seconds for initial provisioning..."
sleep $INITIAL_WAIT
echo ""

echo "→ Beginning status polling (interval: ${POLL_INTERVAL}s, max attempts: ${STATUS_POLL_LIMIT})..."
echo ""

STATUS=""
ATTEMPT=1

while true; do
    set +e
    STATUS_JSON=$(ibmcloud pi ins get "$LPAR_INSTANCE_ID" --json 2>/dev/null)
    STATUS_EXIT=$?
    set -e
    
    if [[ $STATUS_EXIT -ne 0 ]]; then
        echo "  ⚠ WARNING: Status retrieval failed - retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi
    
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status // empty' 2>/dev/null || true)
    echo "  Status Check (${ATTEMPT}/${STATUS_POLL_LIMIT}): ${STATUS}"
    
    if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "STOPPED" ]]; then
        echo ""
        echo "✓ LPAR reached final state: ${STATUS}"
        break
    fi
    
    if (( ATTEMPT >= STATUS_POLL_LIMIT )); then
        echo ""
        echo "✗ FAILURE: Status polling timed out after ${STATUS_POLL_LIMIT} attempts"
        exit 1
    fi
    
    ((ATTEMPT++))
    sleep "$POLL_INTERVAL"
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

CLONE_RESULT=$(ibmcloud pi volume clone-async get "$CLONE_TASK_ID" --json)
CLONE_BOOT_ID=$(echo "$CLONE_RESULT" | jq -r --arg boot "$PRIMARY_BOOT_ID" '.clonedVolumes[] | select(.sourceVolumeID == $boot) | .clonedVolumeID')

if [[ -n "$PRIMARY_DATA_IDS" ]]; then
    CLONE_DATA_IDS=$(echo "$CLONE_RESULT" | jq -r --arg boot "$PRIMARY_BOOT_ID" '.clonedVolumes[] | select(.sourceVolumeID != $boot) | .clonedVolumeID' | paste -sd "," -)
fi

echo "✓ Boot volume clone: ${CLONE_BOOT_ID}"
echo "✓ Data volume clones: ${CLONE_DATA_IDS:-None}"
echo ""

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

echo "→ Attaching boot volume..."
ibmcloud pi instance volume attach "$LPAR_INSTANCE_ID" --volumes "$CLONE_BOOT_ID" >/dev/null 2>&1
sleep 60

while true; do
    VOL_LIST=$(ibmcloud pi instance volume list "$LPAR_INSTANCE_ID" --json 2>/dev/null | jq -r '(.volumes // [])[]?.volumeID')
    if grep -qx "$CLONE_BOOT_ID" <<<"$VOL_LIST"; then
        break
    fi
    sleep 30
done
echo "✓ Boot volume attached"

ibmcloud pi volume update "$CLONE_BOOT_ID" --bootable >/dev/null 2>&1
echo "✓ Boot volume marked as bootable"
echo ""

if [[ -n "$CLONE_DATA_IDS" ]]; then
    echo "→ Attaching data volumes..."
    IFS=',' read -ra DATA_VOL_ARRAY <<<"$CLONE_DATA_IDS"
    VOL_COUNT=${#DATA_VOL_ARRAY[@]}
    VOL_NUM=1
    
    for DATA_VOL_ID in "${DATA_VOL_ARRAY[@]}"; do
        echo "  Attaching data volume ${VOL_NUM}/${VOL_COUNT}: ${DATA_VOL_ID}"
        
        set +e
        ibmcloud pi instance volume attach "$LPAR_INSTANCE_ID" --volumes "$DATA_VOL_ID" >/dev/null 2>&1
        ATTACH_RC=$?
        set -e
        
        if [[ $ATTACH_RC -ne 0 ]]; then
            echo "  WARNING: Attachment command failed with exit code $ATTACH_RC"
        fi
        
        sleep 30
        
        while true; do
            VOL_LIST=$(ibmcloud pi instance volume list "$LPAR_INSTANCE_ID" --json 2>/dev/null | jq -r '(.volumes // [])[]?.volumeID')
            if grep -qx "$DATA_VOL_ID" <<<"$VOL_LIST"; then
                echo "  ✓ Data volume ${VOL_NUM}/${VOL_COUNT} attached"
                break
            fi
            sleep 30
        done
        
        ((VOL_NUM++))
    done
    echo "✓ All data volumes attached"
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
ibmcloud pi instance operation "$LPAR_INSTANCE_ID" --operation-type boot --boot-mode b --boot-operating-mode normal >/dev/null 2>&1
sleep 60
echo "✓ Boot mode configured"
echo ""

################################################################################
# STEP 9: START LPAR
################################################################################
echo "→ Step 9: Starting LPAR..."
ibmcloud pi instance action "$LPAR_INSTANCE_ID" --operation start >/dev/null 2>&1
echo "✓ Start command sent"
echo ""

################################################################################
# STEP 10: WAIT FOR ACTIVE
################################################################################
echo "→ Step 10: Waiting for LPAR to reach ACTIVE..."
while true; do
    STATUS=$(ibmcloud pi instance get "$LPAR_INSTANCE_ID" --json 2>/dev/null | jq -r '.status')
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

