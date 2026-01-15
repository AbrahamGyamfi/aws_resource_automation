#!/usr/bin/env bash


# Script: cleanup_resources.sh
# Purpose: Clean up all AWS resources with logging and safety checks
# Author: DevOps Automation Lab
# Date: December 2025
# Usage: ./cleanup_resources.sh [--dry-run]

set -euo pipefail

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common_functions.sh"

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="cleanup_resources.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/cleanup_$(date +%Y%m%d_%H%M%S).log"
PROJECT_TAG="AutomationLab"
SCRIPT_MANAGED_TAG="ScriptManaged"
DRY_RUN=false

# Parse command line arguments
if [ "${1:-}" == "--dry-run" ]; then
    DRY_RUN=true
    print_info "🔍 DRY-RUN MODE: No resources will be deleted"
    log "INFO" "Cleanup script started in dry-run mode"
fi

# ===========================
# SCRIPT-SPECIFIC FUNCTIONS
# ===========================

# Override get_region to support "all regions" option
get_region() {
    local default_region="eu-west-1"
    
    echo ""
    echo "Available AWS Regions:"
    echo "  1. eu-west-1 (Ireland)"
    echo "  2. us-east-1 (N. Virginia)"
    echo "  3. us-west-2 (Oregon)"
    echo "  4. ap-southeast-1 (Singapore)"
    echo "  5. All regions"
    echo "  6. Custom region"
    echo ""
    
    read -p "Enter region number or press Enter for eu-west-1 [$default_region]: " region_choice
    
    case "$region_choice" in
        1|"") REGION="eu-west-1" ;;
        2) REGION="us-east-1" ;;
        3) REGION="us-west-2" ;;
        4) REGION="ap-southeast-1" ;;
        5) REGION="all" ;;
        6)
            read -p "Enter custom region: " REGION
            ;;
        *)
            REGION="$default_region"
            ;;
    esac
    
    log "INFO" "Selected region: $REGION"
    print_info "Selected region: $REGION"
}

# Get list of regions to clean
get_regions_list() {
    if [ "$REGION" == "all" ]; then
        REGIONS=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>> "$LOG_FILE")
        log "INFO" "Will clean all regions: $REGIONS"
    else
        REGIONS="$REGION"
        log "INFO" "Will clean region: $REGIONS"
    fi
}

# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws sts get-caller-identity >> "$LOG_FILE" 2>&1; then
        print_error "AWS credentials are not configured properly"
        exit 1
    fi
    
    print_success "AWS credentials verified"
}

# Confirm cleanup
confirm_cleanup() {
    print_header "WARNING: Resource Cleanup"
    
    if [ "$SCRIPT_SESSION_ID" != "ALL" ]; then
        cat <<EOF
This script will DELETE the following resources:
  Filter 1: Project=$PROJECT_TAG
  Filter 2: $SCRIPT_MANAGED_TAG=$SCRIPT_SESSION_ID
  
  Resources:
    - EC2 instances
    - EC2 key pairs
    - Security groups
    - S3 buckets (and all contents)
    - Local files (*.pem, welcome.txt)

Region(s): $REGION

⚠ ONLY resources created by THIS script session will be deleted! ⚠
⚠ THIS ACTION CANNOT BE UNDONE! ⚠
EOF
    else
        cat <<EOF
This script will DELETE ALL resources tagged with Project=$PROJECT_TAG:
  - EC2 instances
  - EC2 key pairs  
  - Security groups
  - S3 buckets (and all contents)
  - Local files (*.pem, welcome.txt)

Region(s): $REGION

⚠ WARNING: This will delete ALL resources with the Project tag! ⚠
⚠ THIS ACTION CANNOT BE UNDONE! ⚠
EOF
    fi
    
    echo ""
    read -p "Are you absolutely sure you want to continue? (type 'yes' to confirm): " CONFIRM
    
    if [ "$CONFIRM" != "yes" ]; then
        log "INFO" "Cleanup cancelled by user"
        echo "Cleanup cancelled."
        exit 0
    fi
    
    log "INFO" "User confirmed cleanup"
    print_info "Starting cleanup process..."
}

# Terminate EC2 instances
terminate_instances() {
    local region="$1"
    
    log "INFO" "Checking for EC2 instances in $region"
    
    # Build filter based on whether we have a specific session ID
    local filters="Name=tag:Project,Values=$PROJECT_TAG Name=instance-state-name,Values=running,stopped,stopping,pending"
    if [ "$SCRIPT_SESSION_ID" != "ALL" ]; then
        filters="$filters Name=tag:$SCRIPT_MANAGED_TAG,Values=$SCRIPT_SESSION_ID"
    fi
    
    local instance_ids=$(aws ec2 describe-instances \
        --region "$region" \
        --filters $filters \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$instance_ids" ]; then
        print_info "  No EC2 instances found in $region"
        return
    fi
    
    print_info "  Found instances in $region: $instance_ids"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "  [DRY-RUN] Would terminate instances: $instance_ids"
        print_info "  [DRY-RUN] Would wait for termination to complete"
        return 0
    fi
    
    if aws ec2 terminate-instances \
        --instance-ids $instance_ids \
        --region "$region" >> "$LOG_FILE" 2>&1; then
        
        print_info "  ⏳ Waiting for instances to terminate..."
        aws ec2 wait instance-terminated \
            --instance-ids $instance_ids \
            --region "$region" 2>> "$LOG_FILE" || true
        
        print_success "  EC2 instances terminated in $region"
    else
        print_error "  Failed to terminate instances in $region"
    fi
}

# Delete key pairs
delete_key_pairs() {
    local region="$1"
    
    log "INFO" "Checking for key pairs in $region"
    
    # Try to get key pairs from state file first
    local tracked_keys=""
    if [ -f "$STATE_FILE" ] && [ "$SCRIPT_SESSION_ID" != "ALL" ]; then
        tracked_keys=$(get_resources_from_state "$SCRIPT_SESSION_ID" "key_pair" 2>/dev/null || echo "")
    fi
    
    # Also query AWS for key pairs
    local aws_keys=$(aws ec2 describe-key-pairs \
        --region "$region" \
        --query 'KeyPairs[?starts_with(KeyName, `devops-keypair`)].KeyName' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    # Combine both sources
    local key_pairs=$(echo -e "${tracked_keys}\n${aws_keys}" | sort -u | grep -v '^$')
    
    if [ -z "$key_pairs" ]; then
        print_info "  No key pairs found in $region"
        return
    fi
    
    for key in $key_pairs; do
        if [ "$DRY_RUN" = true ]; then
            print_info "  [DRY-RUN] Would delete key pair: $key"
            if [ -f "${key}.pem" ]; then
                print_info "  [DRY-RUN] Would remove local file: ${key}.pem"
            fi
            continue
        fi
        
        if aws ec2 delete-key-pair \
            --key-name "$key" \
            --region "$region" 2>> "$LOG_FILE"; then
            print_success "  Deleted key pair: $key"
            
            # Remove local .pem file if exists
            if [ -f "${key}.pem" ]; then
                rm -f "${key}.pem"
                print_success "  Removed local file: ${key}.pem"
            fi
        else
            print_warning "  Could not delete key pair: $key"
        fi
    done
}

# Delete security groups
delete_security_groups() {
    local region="$1"
    
    log "INFO" "Checking for security groups in $region"
    
    # Wait a bit to ensure instances are fully terminated
    sleep 5
    
    # Build filter based on whether we have a specific session ID
    local filters="Name=tag:Project,Values=$PROJECT_TAG"
    if [ "$SCRIPT_SESSION_ID" != "ALL" ]; then
        filters="$filters Name=tag:$SCRIPT_MANAGED_TAG,Values=$SCRIPT_SESSION_ID"
    fi
    
    local sg_ids=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters $filters \
        --query 'SecurityGroups[*].GroupId' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$sg_ids" ]; then
        print_info "  No security groups found in $region"
        return
    fi
    
    for sg_id in $sg_ids; do
        if [ "$DRY_RUN" = true ]; then
            print_info "  [DRY-RUN] Would delete security group: $sg_id"
            continue
        fi
        
        if aws ec2 delete-security-group \
            --group-id "$sg_id" \
            --region "$region" 2>> "$LOG_FILE"; then
            print_success "  Deleted security group: $sg_id"
        else
            print_warning "  Could not delete security group: $sg_id may have dependencies"
        fi
    done
}

# Delete S3 buckets
delete_s3_buckets() {
    log "INFO" "Checking for S3 buckets"
    
    local buckets=$(aws s3api list-buckets \
        --query 'Buckets[?starts_with(Name, `devops-automation-lab`)].Name' \
        --output text 2>> "$LOG_FILE" || echo "")
    
    if [ -z "$buckets" ]; then
        print_info "  No S3 buckets found"
        return
    fi
    
    for bucket in $buckets; do
        # Get bucket region
        local bucket_region=$(aws s3api get-bucket-location \
            --bucket "$bucket" \
            --query 'LocationConstraint' \
            --output text 2>> "$LOG_FILE" || echo "us-east-1")
        
        # Handle us-east-1 (returns null)
        if [ "$bucket_region" == "None" ] || [ -z "$bucket_region" ]; then
            bucket_region="us-east-1"
        fi
        
        # Check if we should clean this bucket based on region filter
        if [ "$REGION" != "all" ] && [ "$REGION" != "$bucket_region" ]; then
            print_info "  Skipping bucket $bucket in $bucket_region"
            continue
        fi
        
        # Verify it has the right tags
        local bucket_tags=$(aws s3api get-bucket-tagging \
            --bucket "$bucket" 2>> "$LOG_FILE" || echo "")
        
        local has_project_tag=$(echo "$bucket_tags" | grep -o "$PROJECT_TAG" || echo "")
        
        # If we have a specific session ID, also check for ScriptManaged tag
        local is_script_managed=true
        if [ "$SCRIPT_SESSION_ID" != "ALL" ]; then
            local has_script_tag=$(echo "$bucket_tags" | grep -o "$SCRIPT_SESSION_ID" || echo "")
            if [ -z "$has_script_tag" ]; then
                is_script_managed=false
            fi
        fi
        
        if [ -n "$has_project_tag" ] && [ "$is_script_managed" == "true" ]; then
            if [ "$DRY_RUN" = true ]; then
                print_info "  [DRY-RUN] Would empty and delete bucket: $bucket"
                print_info "  [DRY-RUN] Would delete all object versions and delete markers"
                continue
            fi
            
            print_info "  Emptying bucket: $bucket"
            
            # Delete all versions
            aws s3api list-object-versions \
                --bucket "$bucket" \
                --output json \
                --query 'Versions[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
            jq -c '.[]?' 2>> "$LOG_FILE" | \
            while read -r obj; do
                [ -z "$obj" ] && continue
                local key=$(echo "$obj" | jq -r '.Key')
                local version=$(echo "$obj" | jq -r '.VersionId')
                aws s3api delete-object \
                    --bucket "$bucket" \
                    --key "$key" \
                    --version-id "$version" >> "$LOG_FILE" 2>&1 || true
            done
            
            # Delete all delete markers
            aws s3api list-object-versions \
                --bucket "$bucket" \
                --output json \
                --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
            jq -c '.[]?' 2>> "$LOG_FILE" | \
            while read -r obj; do
                [ -z "$obj" ] && continue
                local key=$(echo "$obj" | jq -r '.Key')
                local version=$(echo "$obj" | jq -r '.VersionId')
                aws s3api delete-object \
                    --bucket "$bucket" \
                    --key "$key" \
                    --version-id "$version" >> "$LOG_FILE" 2>&1 || true
            done
            
            # Fallback: force empty with s3 rb then delete
            aws s3 rb "s3://$bucket" --force >> "$LOG_FILE" 2>&1
            
            # Verify bucket is deleted
            if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
                print_success "  Deleted bucket: $bucket"
            else
                print_warning "  Could not delete bucket: $bucket"
            fi
        fi
    done
}

# Clean up tracking infrastructure (S3 bucket and local file)
cleanup_tracking_infrastructure() {
    log "INFO" "Cleaning up tracking infrastructure"
    
    # Get AWS account ID for bucket name
    local account_id=$(aws sts get-caller-identity --query Account --output text 2>&1 | grep -E '^[0-9]{12}$' || echo "")
    
    if [ -z "$account_id" ]; then
        print_warning "  Could not determine AWS account ID, skipping tracking bucket cleanup"
        return
    fi
    
    local tracking_bucket="automation-state-file-${account_id}"
    
    # Dry-run check
    if [ "$DRY_RUN" = true ]; then
        print_info "  [DRY-RUN] Would empty tracking bucket: $tracking_bucket"
        print_info "  [DRY-RUN] Would delete all versions and delete markers"
        print_info "  [DRY-RUN] Would delete tracking bucket: $tracking_bucket"
        if [ -f "$STATE_FILE" ]; then
            print_info "  [DRY-RUN] Would remove local state file: $STATE_FILE"
        fi
        return 0
    fi
    
    # Check if tracking bucket exists
    if aws s3api head-bucket --bucket "$tracking_bucket" 2>> "$LOG_FILE"; then
        print_info "  Emptying tracking bucket: $tracking_bucket"
        
        # Delete all versions
        aws s3api list-object-versions \
            --bucket "$tracking_bucket" \
            --output json \
            --query 'Versions[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
        jq -c '.[]?' 2>> "$LOG_FILE" | \
        while read -r obj; do
            [ -z "$obj" ] && continue
            local key=$(echo "$obj" | jq -r '.Key')
            local version=$(echo "$obj" | jq -r '.VersionId')
            aws s3api delete-object \
                --bucket "$tracking_bucket" \
                --key "$key" \
                --version-id "$version" >> "$LOG_FILE" 2>&1 || true
        done
        
        # Delete all delete markers
        aws s3api list-object-versions \
            --bucket "$tracking_bucket" \
            --output json \
            --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' 2>> "$LOG_FILE" | \
        jq -c '.[]?' 2>> "$LOG_FILE" | \
        while read -r obj; do
            [ -z "$obj" ] && continue
            local key=$(echo "$obj" | jq -r '.Key')
            local version=$(echo "$obj" | jq -r '.VersionId')
            aws s3api delete-object \
                --bucket "$tracking_bucket" \
                --key "$key" \
                --version-id "$version" >> "$LOG_FILE" 2>&1 || true
        done
        
        # Fallback: force empty with s3 rb then delete
        aws s3 rb "s3://$tracking_bucket" --force >> "$LOG_FILE" 2>&1
        
        # Verify bucket is deleted
        if ! aws s3api head-bucket --bucket "$tracking_bucket" 2>/dev/null; then
            print_success "  Deleted tracking bucket: $tracking_bucket"
        else
            print_warning "  Could not delete tracking bucket: $tracking_bucket"
        fi
    else
        print_info "  Tracking bucket does not exist"
    fi
    
    # Remove local state file (need to change permissions first)
    if [ -f "$STATE_FILE" ]; then
        chmod 644 "$STATE_FILE" 2>> "$LOG_FILE" || true
        rm -f "$STATE_FILE"
        print_success "  Removed local state file: $STATE_FILE"
    fi
}

# Clean up local files
cleanup_local_files() {
    log "INFO" "Cleaning up local files"
    
    # Dry-run check
    if [ "$DRY_RUN" = true ]; then
        local would_delete=0
        if [ -f "welcome.txt" ]; then
            print_info "  [DRY-RUN] Would remove welcome.txt"
            ((would_delete++))
        fi
        for pem_file in devops-keypair-*.pem; do
            if [ -f "$pem_file" ]; then
                print_info "  [DRY-RUN] Would remove $pem_file"
                ((would_delete++))
            fi
        done
        if [ $would_delete -eq 0 ]; then
            print_info "  [DRY-RUN] No local files to clean"
        else
            print_info "  [DRY-RUN] Would clean up $would_delete local file(s)"
        fi
        return 0
    fi
    
    local files_deleted=0
    
    # Remove welcome.txt
    if [ -f "welcome.txt" ]; then
        rm -f welcome.txt
        print_success "  Removed welcome.txt"
        ((files_deleted++))
    fi
    
    # Remove any remaining .pem files
    for pem_file in devops-keypair-*.pem; do
        if [ -f "$pem_file" ]; then
            rm -f "$pem_file"
            print_success "  Removed $pem_file"
            ((files_deleted++))
        fi
    done
    
    if [ $files_deleted -eq 0 ]; then
        print_info "  No local files to clean"
    else
        print_success "  Cleaned up $files_deleted local file(s)"
    fi
}

# Display summary
display_summary() {
    print_header "Cleanup Complete!"
    
    if [ "$DRY_RUN" = true ]; then
        cat <<EOF | tee -a "$LOG_FILE"
DRY-RUN Summary - No resources were actually deleted:
  • EC2 instances would be terminated
  • Key pairs would be deleted
  • Security groups would be removed
  • S3 buckets would be emptied and deleted
  • Tracking infrastructure would be cleaned (S3 bucket and local file)
  • Local files would be cleaned up

Region(s): $REGION
Project tag: $PROJECT_TAG

To perform actual cleanup, run without --dry-run flag
Log file saved to: $LOG_FILE
==========================================
EOF
    else
        cat <<EOF | tee -a "$LOG_FILE"
Summary of cleanup actions:
  ✓ EC2 instances terminated
  ✓ Key pairs deleted
  ✓ Security groups removed
  ✓ S3 buckets emptied and deleted
  ✓ Tracking infrastructure cleaned (S3 bucket and local file)
  ✓ Local files cleaned up

Region(s) cleaned: $REGION
Project tag: $PROJECT_TAG

Log file saved to: $LOG_FILE
==========================================
EOF
    fi
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Initialize
    init_logging
    print_header "AWS Resource Cleanup Script"
    
    # Validate and setup
    validate_aws_cli
    get_script_session_id
    get_region
    get_regions_list
    verify_credentials
    confirm_cleanup
    
    echo ""
    
    # Clean resources in each region
    for current_region in $REGIONS; do
        print_header "Cleaning region: $current_region"
        
        print_info "[1/3] Terminating EC2 instances..."
        terminate_instances "$current_region"
        
        print_info "[2/3] Deleting key pairs..."
        delete_key_pairs "$current_region"
        
        print_info "[3/3] Deleting security groups..."
        delete_security_groups "$current_region"
    done
    
    # S3 buckets (region-aware but handled separately)
    print_header "Cleaning S3 Buckets"
    print_info "[4/5] Deleting S3 buckets..."
    delete_s3_buckets
    
    # Tracking infrastructure cleanup
    print_header "Tracking Infrastructure"
    print_info "[5/5] Cleaning up tracking bucket and local file..."
    cleanup_tracking_infrastructure
    
    # Local cleanup
    print_header "Local Cleanup"
    print_info "[6/6] Cleaning up local files..."
    cleanup_local_files
    
    # Display summary
    display_summary
    
    log "SUCCESS" "Cleanup completed successfully"
}

# Run main function
main "$@"
