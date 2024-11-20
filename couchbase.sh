#!/bin/bash

# Config
USERDISK="nvme1n1"
CB_VG_NAME="VGD01"
LVS=("tmpquery:10", "data:100_PER")
PV_NAME="/dev/nvme1n1"
CB_HOME_DIR="/opt/couchbase/bin"
CB_ADMIN_USER="admin"
CB_ADMIN_PWD="admin12345"
CB_DATA_PATH="/data"
CB_INDEX_PATH="/data"
CB_OWNER="couchbase"
CB_GROUP="couchbase"
CB_AUDIT_DIR="/logs/auditLogs/"
CB_INDEXER_SETTINGS=1
AWS_METADATA_ENDPOINT="http://169.254.169.254/latest"
FTS_MEM=256
CBAAS_MEM=1024
EVEN_MEM=256
AUDIT_EVENTS_DISABLE=8243,8255,8257,20480,20483,20485,20488,20489,20490,20491,20492,20493,20494,20495,20496,20497,20498,20499,20500,20501,20502,20503,20504,20505,20506,20507,20508,20509,20510,20511,20512,20513,20514,20515,20516,20517,20518,20519,20520,20521,20522,20523,20524,20525,20526,20527,20528,20529,20530,20531,20532,20533,20534,20535,20536,20537,20538,20539,20540,20541,20542,20543,20544,20545
CB_GROUPS=("a", "b", "c")
EC2_DOMAIN="ec2.internal"
ADD_NODE_RETRY_SECS=120

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/log"

MSG_STATUS_NO=0
MSG_STATUS_STARTED="STARTED"
MSG_STATUS_COMPLETED="COMPLETED"
MSG_STATUS_FAILED="FAILED"

# Inputs from Terraform
INIT_NODE=${INIT_CLUSTER_NODE_IP}
CLUSTER_VIP=${CLUSTER_VIP_ENDPOINT}
CB_DATA_MEMORY=${DATA_NODE_MEMORY}
CB_IDXQRY_MEMORY=${IDXQRY_MEMORY_MEM}

f_run_task_wrapper() {
    f_run_task_wrapper_continue "$@" || {
        exit 1
    }
}

f_run_task_wrapper_continue() {
    local TASK_NAME=$1
    shift

    f_print_task "$${TASK_NAME}" "$${MSG_STATUS_STARTED}"
    "$@" || {
        f_print_task "$${TASK_NAME}" "$${MSG_STATUS_FAILED}"
        return 1
    }
    f_print_task "$${TASK_NAME}" "$${MSG_STATUS_COMPLETED}"
}

f_print_task() {
    local MSG_CONTENT="$1"
    local MSG_STATUS="$2"

    if [[ "$${MSG_STATUS}" == "$${MSG_STATUS_STARTED}" ]]; then
        MSG_STATUS_NO=`expr $${MSG_STATUS_NO} + 1`
        echo ""
    fi

    echo "[TASK $${MSG_STATUS_NO}] $${MSG_CONTENT} ($${MSG_STATUS})"
}

f_init_node() {
    local PROVISIONED="$1"

    f_create_cb_dir $${CB_AUDIT_DIR}
    HOSTNAME_SELF=$(hostname | cut -d "." -f 1).$${EC2_DOMAIN}

    if [[ "$${PROVISIONED}" == "true" ]]; then
        HOSTNAME_STRING=""
    else
        HOSTNAME_STRING="--node-init-hostname $${HOSTNAME_SELF}"
    fi

    $${CB_HOME_DIR}/couchbase-cli node-init -c localhost -username $${CB_ADMIN_USER} \
        -password $${CB_ADMIN_PWD} \
        --node-init-data-path "$${CB_DATA_PATH}" \
        --node-init-index-path "$${CB_INDEX_PATH}" \
        $${HOSTNAME_STRING}
}

f_init_cluster() {
    local CLUSTER_NAME="$1"
    local SERVICES="$2"
    local DEPLOYMENT_TYPE="$3"
    local DATA_NODE_MEM="$4"
    local INDEX_QUERY_MEM="$5"
    local GROUP_NAME="$6"
    local EXISTING_GROUP='Group 1'

    if [[ "$${DEPLOYMENT_TYPE}" == "standard" ]]; then
        DATA_MEMORY=$(bc <<< "scale=2; $${DATA_NODE_MEM}*0.65")
        INDEX_MEMORY=$(bc <<< "scale=2; $${INDEX_QUERY_MEM}*0.15")
    else
        DATA_MEMORY=$(bc <<< "scale=2; $${DATA_NODE_MEM}*0.65")
        INDEX_MEMORY=$(bc <<< "scale=2; $${INDEX_QUERY_MEM}*0.15")
    fi

    DATA_MEMORY=${DATA_MEMORY%.*}
    INDEX_MEMORY=${INDEX_MEMORY%.*}

    echo "DATA Memory: $${DATA_MEMORY}"
    echo "INDEX_MEMORY: $${INDEX_MEMORY}"

    f_run_adhoc "Initializing cluster" "$${CB_HOME_DIR}/couchbase-cli cluster-init \
        -c localhost --cluster-username $${CB_ADMIN_USER} --cluster-password $${CB_ADMIN_PWD} \
        -services $${SERVICES} \
        -cluster-ramsize 4096"

    f_run_adhoc "setting cluster name to $${CLUSTER_NAME}" "$${CB_HOME_DIR}/couchbase-cli setting-cluster \
        -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
        -cluster-name=$${CLUSTER_NAME}"

    f_run_adhoc "setting failover parameters" "$${CB_HOME_DIR}/couchbase-cli setting-autofailover \
        -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
        --enable-auto-failover 1 \
        -auto-failover-timeout 30 \
        -enable-failover-on-data-disk-issues 1 \
        -failover-data-disk-period 60 \
        --enable-failover-of-server-groups 1 \
        --max-failovers 1"

    f_run_adhoc "Setting audit parameters" "$${CB_HOME_DIR}/couchbase-cli setting-audit \
        -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
        -set-audit-enabled 1 \
        --audit-log-rotate-interval 604800 \
        -audit-log-path $${CB_AUDIT_DIR} \
        --disable-events $${AUDIT_EVENTS_DISABLE}"


    f_run_adhoc "Setting memory parameters as per configuration" "$${CB_HOME_DIR}/couchbase-cli \
            setting-cluster -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
            --cluster-ramsize $${DATA_MEMORY} \
            --cluster-index-ramsize $${INDEX_MEMORY} \
            --cluster-fts-ramsize $${FTS_MEM} \
            --cluster-eventing-ramsize $${EVEN_MEM} \
            --cluster-analytics-ramsize $${CBAAS_MEM}"

    $${CB_HOME_DIR}/couchbase-cli group-manage \
        -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
        --rename CB$${GROUP_NAME} \
        --group-name 'Group 1'

    local IFS=","
    for GROUP_ITEM in $${CB_GROUPS[@]}; do
        if [[ "$${GROUP_ITEM}" == "$${GROUP_NAME}" ]]; then
            continue
        else
            f_run_adhoc "Creating new Couchbase group CB$${GROUP_ITEM}" "$${CB_HOME_DIR}/couchbase-cli \
                create-group-name -c localhost --username $${CB_ADMIN_USER} --password $${CB_ADMIN_PWD} \
                --create-group-name "CB$${GROUP_ITEM}"
        fi
    done
}

f_create_cb_dir() {
    local DIR_NAME=$1

    mkdir -p $${DIR_NAME}
    chown -R $${CB_OWNER}:$${CB_GROUP} $${DIR_NAME}
}

f_run_adhoc() {
    local TASK_MSG=$1
    shift

    echo "[INFO] $${TASK_MSG}"
    "$@" || {
        echo "[ERROR] $${TASK_MSG} failed with errors."
        exit 1
    }
}

f_run_adhoc_with_retry() {
    local TASK_MSG=$1
    shift

    echo "[INFO] $${TASK_MSG}"

    local TIMER=0
    while [ 1 -eq 1 ]; do
        TIMER=`expr $${TIMER} + 2`
        echo $${TIMER}
        if [ "$${TIMER}" -gt "$${ADD_NODE_RETRY_SECS}" ]; then
            echo "[ERROR] Add node operation timed out."
            break
        else
            "$@" && {
                break
            } || {
                echo "[INFO] Retrying after 2 secs "
                sleep 2
                continue
            }
        fi
    done
}

f_get_tag_value() {
    local END_POINT=$1

    curl -s -f --connect-timeout 5 \
        --max-time 10 \
        -retry 5 \
        -retry-delay \
        -retry-max-time 40 \
        $${AWS_METADATA_ENDPOINT}/meta-data/$${END_POINT} || {
        exit 1
    }
}

f_prepare_node() {
    local OPERATION="$1"

    if [[ "$${OPERATION}" != "MOUNT_ONLY" ]]; then
        TASK_MSG="Creating physical volume $${PV_NAME}"
        f_run_task_wrapper "$${TASK_MSG}" pvcreate $${PV_NAME}

        TASK_MSG="Creating Volume Group $${CB_VG_NAME} with $${PV_NAME}"
        f_run_task_wrapper "$${TASK_MSG}" vgcreate "$${CB_VG_NAME}" "$${PV_NAME}"
    fi

    local IFS=","
    for ITEM in $${LVS[@]}; do
        LV_NAME=$(echo $${ITEM} | cut -d ":" -f 1)
        LV_SIZE=$(echo $${ITEM} | cut -d ":" -f 2)

        if [[ "$${LV_SIZE}" == "100_PER" ]]; then
            LV_SIZE="100%FREE"
        else
            LV_SIZE=$${LV_SIZE}
        fi

        if [[ "$${OPERATION}" != "MOUNT_ONLY" ]]; then
            TASK_MSG="Creating logical volume $${LV_NAME} of size $${LV_SIZE}"
            f_run_task_wrapper "$${TASK_MSG}" lvcreate -n "$${LV_NAME}" -L $${LV_SIZE} "$${CB_VG_NAME}"

            TASK_MSG="Creating xfs file system"
            f_run_task_wrapper "$${TASK_MSG}" mkfs.xfs /dev/$${CB_VG_NAME}/$${LV_NAME}
        fi

        f_create_cb_dir $${CB_FS_ROOT}/$${LV_NAME}

        f_run_task_wrapper "$${TASK_MSG}" mount /dev/$${CB_VG_NAME}/$${LV_NAME} $${CB_FS_ROOT}/$${LV_NAME}

        chown $${CB_OWNER}:$${CB_GROUP} $${CB_FS_ROOT}/$${LV_NAME}

        UNIQUE_NAME=$(date +%Y%m%d%H%M%S)
        cp /etc/fstab /etc/fstab_$${UNIQUE_NAME}

        # Updating fstab
        echo "/dev/$${CB_VG_NAME}/$${LV_NAME} $${CB_FS_ROOT}/$${LV_NAME} xfs defaults 0 2" >> /etc/fstab
    done
}

f_add_node() {
    local CLUSTER_NAME="$1"
    local SERVICES="$2"
    local DEPLOYMENT_TYPE="$3"
    local INIT_NODE="$4"
    local NEW_NODE="$5"
    local GROUP_NAME="$6"

    CLUSTER_NODES=()

    IFS=$'\n'
    for line in $(${CB_HOME_DIR}/couchbase-cli server-list -c ${INIT_NODE}:8091 \
        -username ${CB_ADMIN_USER} --password ${CB_ADMIN_PWD}); do
        NODE_ITEM=$(echo $line | awk '{print $2}' | cut -d ":" -f 1)
        CLUSTER_NODES+=(${NODE_ITEM})
    done

    if [[ "${CLUSTER_NODES[@]}" =~ "${NEW_NODE}" ]]; then
        echo "[INFO] Node is already part of the cluster."
    else
        f_run_adhoc_with_retry "Adding node to the cluster." ${CB_HOME_DIR}/couchbase-cli server-add \
            -c ${INIT_NODE}:8091 -username ${CB_ADMIN_USER} -password ${CB_ADMIN_PWD} \
            --server-add ${NEW_NODE}:8091 \
            --server-add-username ${CB_ADMIN_USER} \
            --server-add-password ${CB_ADMIN_PWD} \
            --services ${SERVICES} \
            --group-name ${GROUP_NAME}
    fi
}

f_get_init_node() {
    local CLUSTER_NAME="$1"

    while [[ 1 ]]; do
        INIT_HOST=$(aws ec2 describe-instances \
            --filters Name=tag:initialization,Values=true \
            Name=tag:Name,Values=${CLUSTER_NAME} \
            --query 'Reservations[].Instances[].PrivateDnsName' --output text)

        if [[ "${INIT_HOST}" ]]; then
            continue
        fi
    done
}

f_get_init_node() {
    local CLUSTER_NAME="$1"

    while [[ 1 ]]; do
        INIT_HOST=$(aws ec2 describe-instances \
            --filters Name=tag:initialization,Values=true \
            Name=tag:Name,Values=${CLUSTER_NAME} \
            --query 'Reservations[].Instances[].PrivateDnsName' --output text)

        if [[ "${INIT_HOST}" == "" ]]; then
            continue
        else
            break
        fi
    done
}

# Parameters
CLUSTER_NAME=$(f_get_tag_value "tags/instance/Name")
FILESYSTEMS=$(blkid /dev/${USERDISK})

if [[ "${FILESYSTEMS}" == "" ]]; then
    PROVISIONED="false"
else
    PROVISIONED="true"
fi

TASK_MSG="Installing jq"
f_run_task_wrapper "${TASK_MSG}" yum -y install jq

if [[ "$${PROVISIONED}" == "true" ]]; then
    TASK_MSG="Preparing the Couchbase node."
    f_run_task_wrapper "$${TASK_MSG}" f_prepare_node
else
    TASK_MSG="Preparing the Couchbase node."
    f_run_task_wrapper "$${TASK_MSG}" f_prepare_node "MOUNT_ONLY"
fi

TASK_MSG="Initializing Couchbase node."
f_run_task_wrapper "$${TASK_MSG}" f_init_node "$${PROVISIONED}"

INIT_CLUSTER=$(f_get_tag_value "tags/instance/initialization")
SERVICES=$(f_get_tag_value "tags/instance/service")
DEPLOYMENT_TYPE=$(f_get_tag_value "tags/instance/deployment_type")
AVAIL_ZONE=$(f_get_tag_value "placement/availability-zone")
GROUP_NAME=$${AVAIL_ZONE: -1}
NODE_SELF_IP=$(f_get_tag_value "meta-data/local-ipv4")

if [[ "$${INIT_CLUSTER}" == "" ]] || [[ "$${SERVICES}" == "" ]] || [[ "$${DEPLOYMENT_TYPE}" == "" ]]; then
    echo "[ERROR] Unable to fetch one of the tags."
    exit 1
fi

if [[ "$${INIT_CLUSTER}" == "true" ]] && [[ "$${PROVISIONED}" == "true" ]]; then
    TASK_MSG="Initializing Couchbase cluster."
    f_run_task_wrapper "$${TASK_MSG}" f_init_cluster \
        $${CLUSTER_NAME} $${SERVICES} \
        $${DEPLOYMENT_TYPE} $${CB_DATA_MEMORY} $${CB_IDXQRY_MEMORY} $${GROUP_NAME}
else
    HOSTNAME_SELF=$(hostname | cut -d "." -f 1).$${EC2_DOMAIN}

    if [[ "$${PROVISIONED}" == "true" ]]; then
        INIT_NODE="$${CLUSTER_VIP}"
    else
        INIT_NODE="$${INIT_NODE}"
    fi

    TASK_MSG="Adding node to couchbase cluster."
    f_run_task_wrapper "$${TASK_MSG}" \
        f_add_node $${CLUSTER_NAME} $${SERVICES} \
        "$${DEPLOYMENT_TYPE}" "$${INIT_NODE}" \
        "$${HOSTNAME_SELF}" "CB$${GROUP_NAME}"
fi