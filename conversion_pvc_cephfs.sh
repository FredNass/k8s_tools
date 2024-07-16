#!/bin/bash
# This script allows changing the access mode (RWO or RWX) and the mounter type (kernel or fuse) of a Cephfs PV.
# To do this, it stops all Deployments and StatefulSets of an application (in a namespace), sets the PV to Retain, deletes the PVC and PV, and recreates them with updated values and same volume paths.

set -euo pipefail

# Global variables
WORK_DIR="/usr/local/bin/conversion_pvc_cephfs"
NEW_MODE="ReadWriteMany"  # Default value
MOUNTER_TYPE="kernel"     # Default value
CLUSTER_NAME=""
TIMESTAMP=$(date +%Y%m%d_%H%M)

# Function to display errors and quit
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Function to get the current context
get_current_context() {
    kubectl config current-context 2>/dev/null || echo "default"
}

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Cleanup function
cleanup() {
    log "Cleaning up temporary files..."
    rm -f "${EXECUTION_DIR}"/*.yaml
}

# Checking dependencies
check_dependencies() {
    command -v yq >/dev/null 2>&1 || die "yq is not installed"
    command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed"
    command -v kubectl-neat >/dev/null 2>&1 || die "kubectl-neat is not installed"
}

# Initializing workloads backup file
initialize_workloads_backup() {
    BACKUP_FILE="${EXECUTION_DIR}/workloads_backup_${TIMESTAMP}.txt"
    log "Initializing workloads backup file: $BACKUP_FILE"
    : > "$BACKUP_FILE"
}

# Function to stop deployments and statefulsets
stop_workloads() {
    local ns="$1"
    log "Stopping workloads in namespace $ns"
    
    declare -A dparray sfarray
    
    for dp in $(kubectl get deployments -n "$ns" --no-headers -o custom-columns=":metadata.name"); do
        log "Stopping Deployment $dp"
        dparray["$dp"]=$(kubectl get -n "$ns" deployment "$dp" -o=jsonpath='{.status.replicas}')
        kubectl scale --replicas=0 -n "$ns" deployment "$dp"
    done
    
    for sf in $(kubectl get statefulsets -n "$ns" --no-headers -o custom-columns=":metadata.name"); do
        log "Stopping StatefulSet $sf"
        sfarray["$sf"]=$(kubectl get -n "$ns" statefulset "$sf" -o=jsonpath='{.status.replicas}')
        kubectl scale --replicas=0 -n "$ns" statefulset "$sf"
    done
    
    log "Deleting Completed pods (Jobs)"
    kubectl delete pods -n "$ns" --field-selector=status.phase==Succeeded

    log "Waiting for pods to stop"
    while kubectl get pods -n "$ns" --no-headers | grep -qE "Running|Terminating"; do
        echo -n '.'
        sleep 1
    done
    echo

    # Backing up configurations in an easier-to-restore format
    for key in "${!dparray[@]}"; do
        echo "dp:$key:${dparray[$key]}" >> "$BACKUP_FILE"
    done
    for key in "${!sfarray[@]}"; do
        echo "sf:$key:${sfarray[$key]}" >> "$BACKUP_FILE"
    done
}

# Function to convert a PVC
convert_pvc() {
    local ns="$1" pvc_name="$2"
    
    log "Processing PVC $pvc_name"
    
    local pv_name=$(kubectl get pvc/"${pvc_name}" -n "$ns" -o yaml | yq -r .spec.volumeName)
    local actual_mode=$(kubectl get pv/"${pv_name}" -o yaml | yq -r '.spec.accessModes[]')
    
    log "Current configuration mode is $actual_mode"
    
    log "Backing up PVC"
    kubectl get pvc/"${pvc_name}" -n "$ns" -o yaml > "${EXECUTION_DIR}/pvc_${pvc_name}_ns_${ns}_backup.yaml"
    
    log "Patching PV to Retain"
    kubectl patch pv/"${pv_name}" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
    
    local persistentVolumeReclaimPolicy=$(kubectl get pv/"${pv_name}" -o yaml | yq -r '.spec.persistentVolumeReclaimPolicy')
    [[ "$persistentVolumeReclaimPolicy" != "Retain" ]] && die "PV did not change to Retain. Stopping to protect data."
    
    log "Deleting PVC"
    kubectl delete pvc/"${pvc_name}" -n "$ns"
    
    log "Detaching PV"
    kubectl patch pv/"${pv_name}" -p '{"spec":{"claimRef":null}}'
    
    log "Patching PV for $NEW_MODE"
    kubectl patch pv/"${pv_name}" -p "{\"spec\":{\"accessModes\":[\"$NEW_MODE\"]}}"
    
    log "Backing up PV"
    kubectl get pv/"${pv_name}" -o yaml > "${EXECUTION_DIR}/pv_${pv_name}_ns_${ns}_backup.yaml"
    
    log "Creating new PV"
    sed -e "s/mounter: .*$/mounter: $MOUNTER_TYPE/g" "${EXECUTION_DIR}/pv_${pv_name}_ns_${ns}_backup.yaml" | kubectl neat > "${EXECUTION_DIR}/new_pv_${pv_name}_ns_${ns}.yaml"
    kubectl apply -f "${EXECUTION_DIR}/new_pv_${pv_name}_ns_${ns}.yaml" --force
    
    log "Creating new PVC"
    sed -e "s/$actual_mode/$NEW_MODE/g" "${EXECUTION_DIR}/pvc_${pvc_name}_ns_${ns}_backup.yaml" | kubectl neat > "${EXECUTION_DIR}/new_pvc_${pvc_name}_ns_${ns}.yaml"
    kubectl apply -f "${EXECUTION_DIR}/new_pvc_${pvc_name}_ns_${ns}.yaml"
    
    log "Removing kubectl.kubernetes.io/last-applied-configuration annotation on PVC"
    kubectl annotate pvc "${pvc_name}" kubectl.kubernetes.io/last-applied-configuration- -n "$ns"

    log "Waiting for Bound status for PV and PVC"
    while true; do
        local pvc_status=$(kubectl get pvc/"${pvc_name}" -n "$ns" -o yaml | yq -r '.status.phase')
        local pv_status=$(kubectl get pv/"${pv_name}" -o yaml | yq -r '.status.phase')
        
        if [[ "$pvc_status" == "Bound" && "$pv_status" == "Bound" ]]; then
            log "PV and PVC are in Bound status. Changing PV to persistentVolumeReclaimPolicy Delete"
            kubectl patch pv/"${pv_name}" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'
            break
        fi
        
        sleep 3
    done
}

# Function to restart workloads
restart_workloads() {
    local ns="$1"
    
    log "Restarting workloads in namespace $ns"
    
    # Loading backups
    while IFS=: read -r type name replicas; do
        case $type in
            dp)
                log "Scaling Deployment $name to $replicas replicas"
                kubectl scale --replicas="$replicas" -n "$ns" deployment "$name"
                ;;
            sf)
                log "Scaling StatefulSet $name to $replicas replicas"
                kubectl scale --replicas="$replicas" -n "$ns" statefulset "$name"
                ;;
        esac
    done < "$BACKUP_FILE"
}

# Main function
main() {
    local namespace="$1"
    
    check_dependencies
    
    # Checking namespace
    kubectl get ns "$namespace" >/dev/null 2>&1 || die "Namespace $namespace does not exist in cluster $CLUSTER_NAME"
    
    # Initializing workloads backup file
    initialize_workloads_backup
    
    # Checking for CephFS PVCs
    kubectl get pvc -n "$namespace" | grep ceph-cephfs-sc > /dev/null 2>&1
    if [ $? -ne 0 ]; then 
        die "Namespace $namespace does not contain any cephfs type PVCs. Ending script."
    fi
    
    stop_workloads "$namespace"
    
    for pvc_name in $(kubectl get pvc -n "$namespace" --no-headers | grep ceph-cephfs-sc | awk '{print $1}'); do
        convert_pvc "$namespace" "$pvc_name"
    done
    
    restart_workloads "$namespace"
    
#    cleanup
    log "End of script."
}

# Handling arguments with getopts
while getopts ":n:m:t:c:" opt; do
    case ${opt} in
        n ) namespace="$OPTARG" ;;
        m ) NEW_MODE="$OPTARG" ;;
        t ) MOUNTER_TYPE="$OPTARG" ;;
        c ) CLUSTER_NAME="$OPTARG" ;;
        \? ) die "Invalid option: -$OPTARG" ;;
        : ) die "Option -$OPTARG requires an argument." ;;
    esac
done

# Checking mandatory arguments
[[ -z ${namespace:-} ]] && die "Usage: $0 -n <namespace> [-m <mode>] [-t <mounter_type>] [-c <cluster_name>]. Namespace is required, default mode is ReadWriteMany, default mounter_type is kernel, default cluster_name is current-context."

# Checking mode
[[ "$NEW_MODE" =~ ^(ReadWriteOnce|ReadWriteMany)$ ]] || die "Access mode $NEW_MODE is not a correct value. Accepted values are 'ReadWriteOnce' or 'ReadWriteMany'."

# Checking mounter
[[ "$MOUNTER_TYPE" =~ ^(kernel|fuse)$ ]] || die "Mounter $MOUNTER_TYPE is not a correct value. Accepted values are 'kernel' or 'fuse'."

# Getting cluster name
if [[ -z "$CLUSTER_NAME" ]]; then
    CLUSTER_NAME=$(get_current_context)
fi

# Creating work directory
EXECUTION_DIR="$WORK_DIR/$CLUSTER_NAME/$namespace"
mkdir -p "$EXECUTION_DIR"

# Defining log file
LOG_FILE="${EXECUTION_DIR}/conversion_${TIMESTAMP}.log"

# If a cluster is explicitly specified, use the appropriate context
if [[ -n "$CLUSTER_NAME" ]]; then
    kubectl config use-context "$CLUSTER_NAME" || die "Unable to change context to $CLUSTER_NAME"
fi

# Displaying cluster name, mode, and mounter used
log "Executing on cluster: $CLUSTER_NAME"
log "Access mode used: $NEW_MODE"
log "Mounter type used: $MOUNTER_TYPE"

# Executing the script
main "$namespace"
