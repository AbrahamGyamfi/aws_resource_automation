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

# Initialize script session ID
# This creates or reuses a session ID that uniquely identifies resources
# created by your scripts, enabling safe cleanup that won't affect
# developer-created resources
init_script_session() {
    local script_id_file="${SCRIPT_ID_FILE:-.script_session_id}"
    
    if [ -f "$script_id_file" ]; then
        SCRIPT_SESSION_ID=$(cat "$script_id_file")
        log "INFO" "Using existing script session ID: $SCRIPT_SESSION_ID"
        print_info "Using existing session ID: $SCRIPT_SESSION_ID"
    else
        SCRIPT_SESSION_ID="automation-$(date +%Y%m%d-%H%M%S)-$$"
        echo "$SCRIPT_SESSION_ID" > "$script_id_file"
        log "INFO" "Created new script session ID: $SCRIPT_SESSION_ID"
        print_success "Created new session ID: $SCRIPT_SESSION_ID"
    fi
    
    export SCRIPT_SESSION_ID
}

# Get script session ID for cleanup operations
# Returns the session ID from file, or prompts user if file doesn't exist
get_script_session_id() {
    local script_id_file="${SCRIPT_ID_FILE:-.script_session_id}"
    
    if [ -f "$script_id_file" ]; then
        SCRIPT_SESSION_ID=$(cat "$script_id_file")
        log "INFO" "Found script session ID: $SCRIPT_SESSION_ID"
        print_success "Script session ID loaded: $SCRIPT_SESSION_ID"
    else
        print_warning "No script session ID file found ($script_id_file)"
        print_warning "This file is created when you run create scripts"
        echo ""
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
