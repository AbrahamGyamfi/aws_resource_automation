#!/bin/bash

# Script: deploy_all.sh
# Purpose: Deploy all AWS resources in correct order (Security Group → S3 → EC2)
set -euo pipefail

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "${SCRIPT_DIR}/common_functions.sh"

# ===========================
# CONFIGURATION
# ===========================
SCRIPT_NAME="deploy_all.sh"
LOG_DIR="./logs"
LOG_FILE="${LOG_DIR}/deploy_all_$(date +%Y%m%d_%H%M%S).log"
DRY_RUN=false

# Parse command line arguments
if [ "${1:-}" == "--dry-run" ]; then
    DRY_RUN=true
    print_info "🔍 DRY-RUN MODE: No resources will be created"
    log "INFO" "Script started in dry-run mode"
fi

# ===========================
# DEPLOYMENT FUNCTIONS
# ===========================

# Run a script and capture its status
run_script() {
    local script_name="$1"
    local script_path="${SCRIPT_DIR}/${script_name}"
    local step_num="$2"
    local total_steps="$3"
    
    print_step "$step_num" "$total_steps" "Running ${script_name}..."
    log "INFO" "Executing ${script_name}"
    
    if [ ! -f "$script_path" ]; then
        print_error "Script not found: ${script_path}"
        return 1
    fi
    
    if [ ! -x "$script_path" ]; then
        print_error "Script not executable: ${script_path}. Run: chmod +x ${script_path}"
        return 1
    fi
    
    echo ""
    print_header "${script_name} Execution"
    
    # Run the script with or without dry-run flag
    if [ "$DRY_RUN" = true ]; then
        if ! bash "$script_path" --dry-run 2>&1 | tee -a "$LOG_FILE"; then
            print_error "${script_name} failed"
            return 1
        fi
    else
        if ! bash "$script_path" 2>&1 | tee -a "$LOG_FILE"; then
            print_error "${script_name} failed"
            return 1
        fi
    fi
    
    echo ""
    print_success "✓ ${script_name} completed successfully"
    log "SUCCESS" "${script_name} completed successfully"
    
    # Pause between scripts for readability
    if [ "$step_num" -lt "$total_steps" ]; then
        sleep 2
    fi
}

# Display deployment summary
display_summary() {
    local duration="$1"
    
    if [ "$DRY_RUN" = true ]; then
        print_header "DRY-RUN Deployment Summary"
        cat <<EOF

🔍 This was a DRY-RUN. No actual resources were created.

Scripts that would be executed:
  1. ✓ create_security_group.sh - Network security configuration
  2. ✓ create_s3_bucket.sh       - Object storage with versioning
  3. ✓ create_ec2.sh             - Compute instance with SSH access

Time elapsed: ${duration}s
Log file: $LOG_FILE

To deploy actual resources, run:
  ./deploy_all.sh

To view tracked resources after deployment:
  cat .resource_state.json | jq .

To cleanup all resources:
  ./cleanup_resources.sh
EOF
    else
        print_header "Deployment Complete! 🎉"
        cat <<EOF

All resources have been successfully created and tracked.

Deployed Resources:
  1. ✓ Security Group  - Network access control configured
  2. ✓ S3 Bucket      - Object storage with versioning enabled
  3. ✓ EC2 Instance   - Compute instance ready for SSH access

Time elapsed: ${duration}s
Log file: $LOG_FILE

📋 View all tracked resources:
  cat .resource_state.json | jq .

🔌 Connect to EC2 instance:
  # Check your EC2 creation log for SSH command
  tail -20 logs/ec2_creation_*.log | grep "ssh -i"

🗑️  Cleanup all resources when done:
  ./cleanup_resources.sh
EOF
    fi
}

# Cleanup on error
cleanup_on_error() {
    log "ERROR" "Deployment failed"
    print_error "Deployment failed. Check log file: $LOG_FILE"
    echo ""
    print_warning "⚠️  Some resources may have been created before the failure."
    print_info "Run cleanup script to remove partially created resources:"
    print_info "  ./cleanup_resources.sh"
}

# ===========================
# MAIN EXECUTION
# ===========================
main() {
    local start_time
    local end_time
    local duration
    
    # Set up error trap
    trap cleanup_on_error ERR
    
    # Initialize
    init_logging
    init_script_session
    
    print_header "AWS Infrastructure Deployment"
    
    if [ "$DRY_RUN" = true ]; then
        print_warning "Running in DRY-RUN mode - no resources will be created"
    fi
    
    echo ""
    print_info "This script will deploy the following resources in order:"
    print_info "  1. Security Group (network access control)"
    print_info "  2. S3 Bucket (object storage)"
    print_info "  3. EC2 Instance (compute server)"
    echo ""
    
    # Confirm deployment unless in dry-run mode
    if [ "$DRY_RUN" = false ]; then
        print_warning "⚠️  This will create AWS resources that may incur costs."
        read -p "Continue with deployment? (yes/no): " confirm
        
        if [ "$confirm" != "yes" ]; then
            print_info "Deployment cancelled by user"
            log "INFO" "Deployment cancelled by user"
            exit 0
        fi
        echo ""
    fi
    
    start_time=$(date +%s)
    
    # Deploy resources in order
    TOTAL_STEPS=3
    
    # Step 1: Create Security Group
    run_script "create_security_group.sh" 1 $TOTAL_STEPS
    
    # Step 2: Create S3 Bucket
    run_script "create_s3_bucket.sh" 2 $TOTAL_STEPS
    
    # Step 3: Create EC2 Instance
    run_script "create_ec2.sh" 3 $TOTAL_STEPS
    
    end_time=$(date +%s)
    duration=$((end_time - start_time))
    
    echo ""
    display_summary "$duration"
    
    log "SUCCESS" "Full deployment completed in ${duration}s"
}

# Run main function
main "$@"
