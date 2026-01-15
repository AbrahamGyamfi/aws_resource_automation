#!/bin/bash

# Script: state_functions.sh

STATE_FILE=".resource_state.json"
STATE_BUCKET_PREFIX="automation-state-file"

# Initialize state system
# Syncs from S3 (primary source) to local (read-only backup)
init_state_system() {
    local bucket_name="${STATE_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Try to sync from S3 first (primary source)
    if aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        if aws s3 cp "s3://${bucket_name}/state.json" "$STATE_FILE" --quiet 2>/dev/null; then
            chmod 444 "$STATE_FILE"
            log "INFO" "Synced state file from S3 (primary source)"
            print_info "state data synced from S3"
            return 0
        fi
    fi
    
    # Create new file if nothing exists
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" << 'EOF'
{
  "version": "1.0",
  "current_session": null,
  "sessions": {}
}
EOF
        chmod 444 "$STATE_FILE"
        log "INFO" "Created new state file (will upload to S3)"
    fi
}

# Save resource ID to state system
# Args: resource_type, resource_id, resource_name, region

save_resource_to_state() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    local region="$4"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    # Make file writable temporarily
    chmod u+w "$STATE_FILE" 2>/dev/null || true
    
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
       "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
    
    # Upload to S3 PRIMARY SOURCE immediately
    if upload_state_to_s3; then
        log "INFO" "Saved $resource_type: $resource_id to S3 (primary)"
    else
        log "WARNING" "Failed to save to S3, resource saved locally only"
    fi
    
    # Make local backup read-only (cannot be tampered with)
    chmod 444 "$STATE_FILE"
}

# Upload state file to S3 PRIMARY SOURCE
# Local file is just a synced read-only backup
upload_state_to_s3() {
    local bucket_name="${STATE_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Check if bucket exists, create if not
    if ! aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        log "INFO" "Creating S3 STATE bucket: $bucket_name"
        
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
    
    # Upload to PRIMARY location (state.json)
    if ! aws s3 cp "$STATE_FILE" "s3://${bucket_name}/state.json" --quiet 2>/dev/null; then
        log "ERROR" "Failed to upload to S3 primary source"
        return 1
    fi
    
    log "INFO" "Uploaded state data to S3 (primary source)"
    return 0
}

# Sync state file from S3 primary source to local backup
sync_from_s3() {
    local bucket_name="${STATE_BUCKET_PREFIX}-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo 'unknown')"
    
    # Check if bucket exists first
    if ! aws s3api head-bucket --bucket "$bucket_name" 2>/dev/null; then
        # Bucket doesn't exist - return silently (could be during cleanup)
        return 1
    fi
    
    print_info "Syncing state data from S3 (primary source)..."
    
    # Try primary file first
    if aws s3 cp "s3://${bucket_name}/state.json" "$STATE_FILE" --quiet 2>/dev/null; then
        chmod 444 "$STATE_FILE"
        print_success "state data synced from S3"
        return 0
    else
        print_error "Failed to sync from S3 primary source"
        return 1
    fi
}

# Get all resource IDs for a session from state system
# Syncs from S3 (primary) if local is stale or missing
get_resources_from_state() {
    local session_id="$1"
    local resource_type="$2"  # Optional: ec2, s3, security_group, key_pair
    
    # Try to sync from S3 first if local file is old or missing (silently)
    if [ ! -f "$STATE_FILE" ] || [ -n "$(find "$STATE_FILE" -mmin +5 2>/dev/null)" ]; then
        sync_from_s3 >/dev/null 2>&1 || true
    fi
    
    if [ ! -f "$STATE_FILE" ]; then
        log "WARNING" "state file not found locally or in S3: $STATE_FILE"
        return 1
    fi
    
    if [ -z "$resource_type" ]; then
        # Return all resources for session
        jq -r --arg session "$session_id" \
            '.sessions[$session].resources // {} | to_entries[] | "\(.key): \(.value | map(.id) | join(", "))"' \
            "$STATE_FILE" 2>/dev/null
    else
        # Return specific resource type
        jq -r --arg session "$session_id" --arg type "$resource_type" \
            '.sessions[$session].resources[$type] // [] | map(.id) | .[]' \
            "$STATE_FILE" 2>/dev/null
    fi
}

# ===========================
# S3 STATE MANAGEMENT
# ===========================

# Legacy aliases for backward compatibility
restore_from_s3() {
    sync_from_s3
}

download_STATE_from_s3() {
    sync_from_s3
}

# List all sessions in state system
list_all_sessions() {
    # Sync from S3 first (primary source)
    sync_from_s3 2>/dev/null || true
    
    if [ ! -f "$STATE_FILE" ]; then
        print_warning "No state data found (S3 or local)"
        return 1
    fi
    
    print_header "Tracked Sessions (from S3)"
    jq -r '.sessions | to_entries[] | "\(.key) (created: \(.value.created_at))"' "$STATE_FILE" 2>/dev/null
}

# Display resources for a specific session
show_session_resources() {
    local session_id="$1"
    
    # Sync from S3 first (primary source)
    sync_from_s3 2>/dev/null || true
    
    if [ ! -f "$STATE_FILE" ]; then
        print_warning "No state data found (S3 or local)"
        return 1
    fi
    
    print_header "Resources for Session: $session_id (from S3)"
    jq --arg session "$session_id" \
        '.sessions[$session] // {"error": "Session not found"}' \
        "$STATE_FILE" 2>/dev/null
}

# ===========================
# SESSION MANAGEMENT
# ===========================

# Initialize script session ID
# This creates or reuses a session ID that uniquely identifies resources
# created by your scripts, enabling safe cleanup that won't affect
# developer-created resources
init_script_session() {
    # Initialize state system
    init_state_system
    
    # Check if current session exists in state file
    SCRIPT_SESSION_ID=$(jq -r '.current_session // empty' "$STATE_FILE" 2>/dev/null || echo "")
    
    if [ -n "$SCRIPT_SESSION_ID" ] && [ "$SCRIPT_SESSION_ID" != "null" ]; then
        log "INFO" "Using existing script session ID: $SCRIPT_SESSION_ID"
        print_info "Using existing session ID: $SCRIPT_SESSION_ID"
    else
        SCRIPT_SESSION_ID="automation-$(date +%Y%m%d-%H%M%S)-$$"
        
        # Initialize session in JSON state with current_session
        chmod u+w "$STATE_FILE" 2>/dev/null || true
        local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local temp_file=$(mktemp)
        jq --arg session "$SCRIPT_SESSION_ID" --arg timestamp "$timestamp" \
            '.current_session = $session | .sessions[$session] = {"created_at": $timestamp, "resources": {}}' \
            "$STATE_FILE" > "$temp_file" && mv "$temp_file" "$STATE_FILE"
        chmod 444 "$STATE_FILE"
        
        log "INFO" "Created new script session ID: $SCRIPT_SESSION_ID"
        print_success "Created new session ID: $SCRIPT_SESSION_ID"
        
        # Upload initial state to S3
        upload_state_to_s3
    fi
    
    export SCRIPT_SESSION_ID
}

# Get script session ID for cleanup operations
# Syncs from S3 (primary) first, then checks local
get_script_session_id() {
    # Sync state data from S3 primary source
    print_info "Syncing state data from S3..."
    init_state_system
    
    # Try to get current session from state file
    if [ -f "$STATE_FILE" ]; then
        SCRIPT_SESSION_ID=$(jq -r '.current_session // empty' "$STATE_FILE" 2>/dev/null || echo "")
        
        if [ -n "$SCRIPT_SESSION_ID" ] && [ "$SCRIPT_SESSION_ID" != "null" ]; then
            log "INFO" "Found script session ID: $SCRIPT_SESSION_ID"
            print_success "Script session ID loaded: $SCRIPT_SESSION_ID"
        else
            # No current session set, let user choose
            print_warning "No current session found in state data"
            list_all_sessions
            echo ""
            read -p "Enter session ID from above, or 'ALL' for all resources: " user_choice
            if [ "$user_choice" == "ALL" ] || [ -z "$user_choice" ]; then
                SCRIPT_SESSION_ID="ALL"
            else
                SCRIPT_SESSION_ID="$user_choice"
            fi
        fi
    else
        # No state data in S3 or locally
        print_warning "No state data found in S3 or locally"
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
