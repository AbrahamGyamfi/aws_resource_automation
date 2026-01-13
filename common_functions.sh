#!/bin/bash

# Script: common_functions.sh
# Purpose: Common utility functions for AWS automation scripts
# Author: DevOps Automation Lab
# Date: December 2025

# ===========================
# UTILITY FUNCTIONS
# ===========================

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log "INFO" "Logging initialized: $LOG_FILE"
}

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo "==========================================" | tee -a "$LOG_FILE"
    echo "$title" | tee -a "$LOG_FILE"
    echo "==========================================" | tee -a "$LOG_FILE"
}

# Print success message
print_success() {
    local message="$1"
    echo "✓ $message" | tee -a "$LOG_FILE"
    log "SUCCESS" "$message"
}

# Print error message and exit
print_error() {
    local message="$1"
    echo "✗ ERROR: $message" | tee -a "$LOG_FILE"
    log "ERROR" "$message"
    exit 1
}

# Print info message
print_info() {
    local message="$1"
    echo "$message" | tee -a "$LOG_FILE"
    log "INFO" "$message"
}

# Print warning message
print_warning() {
    local message="$1"
    echo "⚠ WARNING: $message" | tee -a "$LOG_FILE"
    log "WARNING" "$message"
}

# Validate AWS CLI is installed
validate_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
    fi
    print_success "AWS CLI is installed"
}

# Get AWS region from user
get_region() {
    local default_region="eu-west-1"
    
    echo ""
    echo "Available AWS Regions:"
    echo "  1. eu-west-1 (Ireland)"
    echo "  2. us-east-1 (N. Virginia)"
    echo "  3. us-west-2 (Oregon)"
    echo "  4. ap-southeast-1 (Singapore)"
    echo "  5. Custom region"
    echo ""
    
    read -p "Enter region number or press Enter for eu-west-1 [$default_region]: " region_choice
    
    case "$region_choice" in
        1|"") REGION="eu-west-1" ;;
        2) REGION="us-east-1" ;;
        3) REGION="us-west-2" ;;
        4) REGION="ap-southeast-1" ;;
        5)
            read -p "Enter custom region: " REGION
            ;;
        *)
            print_error "Invalid selection. Exiting."
            ;;
    esac
    
    print_info "Selected region: $REGION"
    export REGION
}

# ===========================
# SCRIPT SESSION MANAGEMENT
# ===========================

# Configuration for tracking system
TRACKING_FILE=".resource_tracking.json"
TRACKING_BUCKET_PREFIX="script-tracking-backup"

# Initialize tracking system
# Syncs from S3 (primary source) to local (read-only backup)
init_tracking_system() {
    local bucket_name="${TRACKING_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Try to sync from S3 first (primary source)
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        if aws s3 cp "s3://${bucket_name}/tracking.json" "$TRACKING_FILE" --quiet 2>/dev/null; then
            chmod 444 "$TRACKING_FILE"
            log "INFO" "Synced tracking file from S3 (primary source)"
            print_info "Tracking data synced from S3"
            return 0
        fi
    fi
    
    # Create new file if nothing exists
    if [ ! -f "$TRACKING_FILE" ]; then
        cat > "$TRACKING_FILE" << 'EOF'
{
  "version": "1.0",
  "sessions": {}
}
EOF
        chmod 444 "$TRACKING_FILE"
        log "INFO" "Created new tracking file (will upload to S3)"
    fi
}

# Save resource ID to tracking system
# Args: resource_type, resource_id, resource_name, region
# PRIMARY: Saves to S3 first, then syncs to local read-only backup
save_resource_to_tracking() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    local region="$4"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Make file writable temporarily
    chmod u+w "$TRACKING_FILE" 2>/dev/null || true
    
    # Update local file first (will be uploaded to S3)
    local temp_file=$(mktemp)
    jq --arg session "$SCRIPT_SESSION_ID" \
       --arg type "$resource_type" \
       --arg id "$resource_id" \
       --arg name "$resource_name" \
       --arg region "$region" \
       --arg timestamp "$timestamp" \
       '.sessions[$session] //= {"created_at": $timestamp, "resources": {}} |
        .sessions[$session].resources[$type] //= [] |
        .sessions[$session].resources[$type] += [{"id": $id, "name": $name, "region": $region, "created_at": $timestamp}]' \
       "$TRACKING_FILE" > "$temp_file" && mv "$temp_file" "$TRACKING_FILE"
    
    # Upload to S3 PRIMARY SOURCE immediately
    if upload_tracking_to_s3; then
        log "INFO" "Saved $resource_type: $resource_id to S3 (primary)"
    else
        log "WARNING" "Failed to save to S3, resource saved locally only"
    fi
    
    # Make local backup read-only (cannot be tampered with)
    chmod 444 "$TRACKING_FILE"
}

# Upload tracking file to S3 PRIMARY SOURCE
# Local file is just a synced read-only backup
upload_tracking_to_s3() {
    local bucket_name="${TRACKING_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Check if bucket exists, create if not
    if ! aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log "INFO" "Creating S3 tracking bucket: $bucket_name"
        
        local region="${REGION:-us-east-1}"
        if [ "$region" == "us-east-1" ]; then
            aws s3api create-bucket --bucket "$bucket_name" --region "$region" 2>/dev/null || return 1
        else
            aws s3api create-bucket --bucket "$bucket_name" --region "$region" \
                --create-bucket-configuration LocationConstraint="$region" 2>/dev/null || return 1
        fi
        
        # Enable versioning for protection
        aws s3api put-bucket-versioning --bucket "$bucket_name" \
            --versioning-configuration Status=Enabled 2>/dev/null || true
        
        # Add encryption
        aws s3api put-bucket-encryption --bucket "$bucket_name" \
            --server-side-encryption-configuration '{
                "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
            }' 2>/dev/null || true
        
        # Block public access
        aws s3api put-public-access-block --bucket "$bucket_name" \
            --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
            2>/dev/null || true
    fi
    
    # Upload to PRIMARY location (tracking.json)
    if ! aws s3 cp "$TRACKING_FILE" "s3://${bucket_name}/tracking.json" --quiet 2>/dev/null; then
        log "ERROR" "Failed to upload to S3 primary source"
        return 1
    fi
    
    # Keep timestamped backup also
    local backup_key="backups/tracking_$(date +%Y%m%d_%H%M%S).json"
    aws s3 cp "$TRACKING_FILE" "s3://${bucket_name}/${backup_key}" --quiet 2>/dev/null || true
    
    log "INFO" "Uploaded tracking data to S3 (primary source)"
    return 0
}

# Sync tracking file from S3 primary source to local backup
sync_from_s3() {
    local bucket_name="${TRACKING_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Check if bucket exists first
    if ! aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        # Bucket doesn't exist - return silently (could be during cleanup)
        return 1
    fi
    
    print_info "Syncing tracking data from S3 (primary source)..."
    
    # Try primary file first
    if aws s3 cp "s3://${bucket_name}/tracking.json" "$TRACKING_FILE" --quiet 2>/dev/null; then
        chmod 444 "$TRACKING_FILE"
        print_success "Tracking data synced from S3"
        return 0
    else
        print_error "Failed to sync from S3 primary source"
        return 1
    fi
}

# Legacy aliases
restore_from_s3() {
    sync_from_s3
}

download_tracking_from_s3() {
    sync_from_s3
}

# List all available backups in S3 (primary source)
list_s3_backups() {
    local bucket_name="${TRACKING_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    print_header "S3 Tracking Data (Primary Source)"
    echo ""
    print_info "Primary file:"
    aws s3 ls "s3://${bucket_name}/tracking.json" 2>/dev/null || print_warning "  No primary file found"
    echo ""
    print_info "Timestamped backups:"
    aws s3 ls "s3://${bucket_name}/backups/" --recursive 2>/dev/null | grep '.json' || \
        print_info "  No backups found"
}

# Get all resource IDs for a session from tracking system
# Syncs from S3 (primary) if local is stale or missing
get_resources_from_tracking() {
    local session_id="$1"
    local resource_type="$2"  # Optional: ec2, s3, security_group, key_pair
    
    # Try to sync from S3 first if local file is old or missing (silently)
    if [ ! -f "$TRACKING_FILE" ] || [ -n "$(find "$TRACKING_FILE" -mmin +5 2>/dev/null)" ]; then
        sync_from_s3 >/dev/null 2>&1 || true
    fi
    
    if [ ! -f "$TRACKING_FILE" ]; then
        log "WARNING" "Tracking file not found locally or in S3: $TRACKING_FILE"
        return 1
    fi
    
    if [ -z "$resource_type" ]; then
        # Return all resources for session
        jq -r --arg session "$session_id" \
            '.sessions[$session].resources // {} | to_entries[] | "\(.key): \(.value | map(.id) | join(", "))"' \
            "$TRACKING_FILE" 2>/dev/null
    else
        # Return specific resource type
        jq -r --arg session "$session_id" --arg type "$resource_type" \
            '.sessions[$session].resources[$type] // [] | map(.id) | .[]' \
            "$TRACKING_FILE" 2>/dev/null
    fi
}

# List all sessions in tracking system
list_all_sessions() {
    # Sync from S3 first (primary source)
    sync_from_s3 2>/dev/null || true
    
    if [ ! -f "$TRACKING_FILE" ]; then
        print_warning "No tracking data found (S3 or local)"
        return 1
    fi
    
    print_header "Tracked Sessions (from S3)"
    jq -r '.sessions | to_entries[] | "\(.key) (created: \(.value.created_at))"' "$TRACKING_FILE" 2>/dev/null
}

# Display resources for a specific session
show_session_resources() {
    local session_id="$1"
    
    # Sync from S3 first (primary source)
    sync_from_s3 2>/dev/null || true
    
    if [ ! -f "$TRACKING_FILE" ]; then
        print_warning "No tracking data found (S3 or local)"
        return 1
    fi
    
    print_header "Resources for Session: $session_id (from S3)"
    jq --arg session "$session_id" \
        '.sessions[$session] // {"error": "Session not found"}' \
        "$TRACKING_FILE" 2>/dev/null
}

# Initialize script session ID
# This creates or reuses a session ID that uniquely identifies resources
# created by your scripts, enabling safe cleanup that won't affect
# developer-created resources
init_script_session() {
    local script_id_file="${SCRIPT_ID_FILE:-.script_session_id}"
    
    # Initialize tracking system
    init_tracking_system
    
    if [ -f "$script_id_file" ]; then
        SCRIPT_SESSION_ID=$(cat "$script_id_file")
        log "INFO" "Using existing script session ID: $SCRIPT_SESSION_ID"
        print_info "Using existing session ID: $SCRIPT_SESSION_ID"
    else
        SCRIPT_SESSION_ID="automation-$(date +%Y%m%d-%H%M%S)-$$"
        echo "$SCRIPT_SESSION_ID" > "$script_id_file"
        chmod 444 "$script_id_file"  # Make read-only
        
        # Initialize session in JSON tracking
        chmod u+w "$TRACKING_FILE" 2>/dev/null || true
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        jq --arg session "$SCRIPT_SESSION_ID" --arg timestamp "$timestamp" \
            '.sessions[$session] = {"created_at": $timestamp, "resources": {}}' \
            "$TRACKING_FILE" > "$TRACKING_FILE.tmp" && mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
        chmod 444 "$TRACKING_FILE"
        
        log "INFO" "Created new script session ID: $SCRIPT_SESSION_ID"
        print_success "Created new session ID: $SCRIPT_SESSION_ID"
        
        # Upload initial state to S3
        upload_tracking_to_s3
    fi
    
    export SCRIPT_SESSION_ID
}

# Get script session ID for cleanup operations
# Syncs from S3 (primary) first, then checks local
get_script_session_id() {
    local script_id_file="${SCRIPT_ID_FILE:-.script_session_id}"
    
    # Sync tracking data from S3 primary source
    print_info "Syncing tracking data from S3..."
    init_tracking_system
    
    # Try to get from local file first
    if [ -f "$script_id_file" ]; then
        SCRIPT_SESSION_ID=$(cat "$script_id_file")
        log "INFO" "Found script session ID: $SCRIPT_SESSION_ID"
        print_success "Script session ID loaded: $SCRIPT_SESSION_ID"
    elif [ -f "$TRACKING_FILE" ]; then
        # Local session file missing but tracking data exists in S3
        print_warning "Session ID file missing, but tracking data found in S3"
        list_all_sessions
        echo ""
        read -p "Enter session ID from above, or 'ALL' for all resources: " user_choice
        if [ "$user_choice" == "ALL" ] || [ -z "$user_choice" ]; then
            SCRIPT_SESSION_ID="ALL"
        else
            SCRIPT_SESSION_ID="$user_choice"
        fi
    else
        # No tracking data in S3 or locally
        print_warning "No tracking data found in S3 or locally"
        read -p "Do you want to clean ALL resources with Project=${PROJECT_TAG}? (yes/no): " cleanup_all
        if [ "$cleanup_all" == "yes" ]; then
            SCRIPT_SESSION_ID="ALL"
            log "INFO" "User chose to clean all resources with Project tag"
        else
            print_error "Cleanup cancelled. No session ID available."
            exit 1
        fi
    fi
    
    export SCRIPT_SESSION_ID
}
