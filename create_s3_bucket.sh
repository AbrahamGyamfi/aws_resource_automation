#!/bin/bash

# Script: create_s3_bucket.sh
# Purpose: Create S3 bucket with versioning and logging
# Author: DevOps Automation Lab
# Date: December 2025
# Usage: ./create_s3_bucket.sh [--dry-run]

set -euo pipefail

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common_functions.sh"

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="create_s3_bucket.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/s3_creation_$(date +%Y%m%d_%H%M%S).log"
BUCKET_NAME="devops-automation-lab-$(date +%s)-$RANDOM"
SAMPLE_FILE="welcome.txt"
SCRIPT_ID_FILE=".script_session_id"
SCRIPT_SESSION_ID=""
DRY_RUN=false

# Parse command line arguments
if [ "${1:-}" == "--dry-run" ]; then
    DRY_RUN=true
    print_info "🔍 DRY-RUN MODE: No resources will be created"
    log "INFO" "Script started in dry-run mode"
fi

# ===========================
# SCRIPT-SPECIFIC FUNCTIONS
# ===========================


# Verify AWS credentials
verify_credentials() {
    log "INFO" "Verifying AWS credentials"
    
    if ! aws sts get-caller-identity --region "$REGION" &>> "$LOG_FILE"; then
        print_error "AWS credentials are not configured properly"
    fi
    
    print_success "AWS credentials verified"
}

# Create sample file
create_sample_file() {
    log "INFO" "Creating sample file: $SAMPLE_FILE"
    
    cat > "$SAMPLE_FILE" << EOF
Welcome to DevOps Automation Lab!
==================================

This file was automatically uploaded by create_s3_bucket.sh script.

Bucket: $BUCKET_NAME
Region: $REGION
Created: $(date)

Project: AWS Resource Automation
Purpose: Learning AWS CLI and Bash scripting

---
This is a demonstration file showing:
- Automated S3 bucket creation
- File upload capabilities
- Versioning management
- Tagging and organization
EOF

    print_success "Sample file created: $SAMPLE_FILE"
}

# Create S3 bucket
create_bucket() {
    log "INFO" "Creating S3 bucket: $BUCKET_NAME"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "  [DRY-RUN] Would create S3 bucket: $BUCKET_NAME"
        print_info "  [DRY-RUN] Region: $REGION"
        if [ "$REGION" != "us-east-1" ]; then
            print_info "  [DRY-RUN] Would set LocationConstraint: $REGION"
        fi
        print_info "  [DRY-RUN] Would track in state file"
        return 0
    fi
    
    # us-east-1 doesn't need LocationConstraint
    if [ "$REGION" == "us-east-1" ]; then
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" &>> "$LOG_FILE"
    else
        aws s3api create-bucket \
            --bucket "$BUCKET_NAME" \
            --region "$REGION" \
            --create-bucket-configuration LocationConstraint="$REGION" &>> "$LOG_FILE"
    fi
    
    if [ $? -eq 0 ]; then
        # Save to JSON tracking file
        save_resource_to_state "s3_bucket" "$BUCKET_NAME" "$BUCKET_NAME" "$REGION"
        
        print_success "Bucket created: $BUCKET_NAME"
    else
        print_error "Failed to create bucket"
    fi
}

# Tag bucket
tag_bucket() {
    log "INFO" "Adding tags to bucket"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "  [DRY-RUN] Would add tags:"
        print_info "    - Project: AutomationLab"
        print_info "    - Environment: Development"
        print_info "    - ManagedBy: BashScript"
        print_info "    - ScriptManaged: $SCRIPT_SESSION_ID"
        print_info "    - CreatedBy: $USER"
        return 0
    fi
    
    aws s3api put-bucket-tagging \
        --bucket "$BUCKET_NAME" \
        --tagging "TagSet=[
            {Key=Project,Value=AutomationLab},
            {Key=Environment,Value=Development},
            {Key=ManagedBy,Value=BashScript},
            {Key=ScriptManaged,Value=$SCRIPT_SESSION_ID},
            {Key=CreatedBy,Value=$USER}
        ]" \
        --region "$REGION" 2>> "$LOG_FILE"
    
    print_success "Tags applied to bucket"
}

# Enable versioning
enable_versioning() {
    log "INFO" "Enabling versioning on bucket"
    
    if [ "$DRY_RUN" = true ]; then
        print_info "  [DRY-RUN] Would enable versioning on bucket"
        return 0
    fi
    
    aws s3api put-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --versioning-configuration Status=Enabled \
        --region "$REGION" 2>> "$LOG_FILE"
    
    if [ $? -eq 0 ]; then
        print_success "Versioning enabled"
    else
        print_error "Failed to enable versioning"
    fi
}

# Apply bucket policy
apply_bucket_policy() {
    log "INFO" "Applying bucket policy"
    
    local bucket_policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicRead",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*"
    }
  ]
}
EOF
)
    
    if aws s3api put-bucket-policy \
        --bucket "$BUCKET_NAME" \
        --policy "$bucket_policy" \
        --region "$REGION" 2>> "$LOG_FILE"; then
        print_success "Bucket policy applied"
    else
        print_warning "Bucket policy not applied (public access might be blocked by default)"
    fi
}

# Upload sample file
upload_file() {
    log "INFO" "Uploading sample file to bucket"
    
    if aws s3 cp "$SAMPLE_FILE" "s3://$BUCKET_NAME/$SAMPLE_FILE" \
        --region "$REGION" &>> "$LOG_FILE"; then
        print_success "File uploaded: $SAMPLE_FILE"
    else
        print_error "Failed to upload file"
    fi
}

# Get bucket details
get_bucket_details() {
    log "INFO" "Retrieving bucket details"
    
    VERSIONING_STATUS=$(aws s3api get-bucket-versioning \
        --bucket "$BUCKET_NAME" \
        --region "$REGION" \
        --query 'Status' \
        --output text 2>> "$LOG_FILE")
    
    print_success "Retrieved bucket details"
}

# List bucket contents
list_bucket_contents() {
    log "INFO" "Listing bucket contents"
    
    echo ""
    echo "Current bucket contents:" | tee -a "$LOG_FILE"
    aws s3 ls "s3://$BUCKET_NAME" --region "$REGION" 2>> "$LOG_FILE" | tee -a "$LOG_FILE"
}

# Display results
display_results() {
    if [ "$DRY_RUN" = true ]; then
        print_header "DRY-RUN Summary - No Resources Created"
        cat <<EOF
Bucket Name:        $BUCKET_NAME (not created)
Region:             $REGION
Versioning Status:  Enabled (would be configured)
Sample File:        $SAMPLE_FILE (not uploaded)
Bucket ARN:         arn:aws:s3:::$BUCKET_NAME (simulated)
==========================================

🔍 This was a DRY-RUN. No actual resources were created.
To create resources, run without --dry-run flag:
  ./create_s3_bucket.sh

Log file saved to: $LOG_FILE
EOF
    else
        print_header "S3 Bucket Created Successfully!"
        cat <<EOF | tee -a "$LOG_FILE"
Bucket Name:        $BUCKET_NAME
Region:             $REGION
Versioning Status:  $VERSIONING_STATUS
Sample File:        $SAMPLE_FILE
Bucket ARN:         arn:aws:s3:::$BUCKET_NAME
==========================================

To list bucket contents:
  aws s3 ls s3://$BUCKET_NAME --region $REGION

To download the file:
  aws s3 cp s3://$BUCKET_NAME/$SAMPLE_FILE ./ --region $REGION

To access via console:
  https://s3.console.aws.amazon.com/s3/buckets/$BUCKET_NAME

Log file saved to: $LOG_FILE
EOF
    fi
}

# Cleanup on error
cleanup_on_error() {
    log "ERROR" "Script failed. Cleaning up..."
    
    if [ -n "${BUCKET_NAME:-}" ]; then
        # Try to delete the bucket if it was created
        aws s3 rb "s3://$BUCKET_NAME" --force --region "$REGION" 2>> "$LOG_FILE" || true
    fi
    
    if [ -f "$SAMPLE_FILE" ]; then
        rm -f "$SAMPLE_FILE" 2>> "$LOG_FILE" || true
    fi
    
    print_error "Script execution failed. Check log file: $LOG_FILE"
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    # Set up error trap
    trap cleanup_on_error ERR
    
    # Initialize
    init_logging
    init_script_session
    print_header "S3 Bucket Creation Script"
    
    # Validate and setup
    validate_aws_cli
    get_region
    verify_credentials
    
    # Create resources
    print_info "[1/8] Creating sample file..."
    create_sample_file
    
    print_info "[2/8] Creating S3 bucket..."
    create_bucket
    
    print_info "[3/8] Adding tags to bucket..."
    tag_bucket
    
    print_info "[4/8] Enabling versioning..."
    enable_versioning
    
    print_info "[5/8] Applying bucket policy..."
    apply_bucket_policy
    
    print_info "[6/8] Uploading sample file..."
    upload_file
    
    print_info "[7/8] Retrieving bucket details..."
    get_bucket_details
    
    print_info "[8/8] Finalizing..."
    list_bucket_contents
    display_results
    
    log "SUCCESS" "S3 bucket creation completed successfully"
}

# Run main function
main "$@"
