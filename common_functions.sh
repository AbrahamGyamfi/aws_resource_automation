#!/bin/bash

# Script: common_functions.sh
# Purpose: Common utility functions for AWS automation scripts
# Author: DevOps Automation Lab
# Date: December 2025

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================
# COLOR CODES
# ===========================
# Check if terminal supports colors
if [ -t 1 ]; then
    COLOR_RESET="\033[0m"
    COLOR_BOLD="\033[1m"
    COLOR_RED="\033[1;31m"
    COLOR_GREEN="\033[1;32m"
    COLOR_YELLOW="\033[1;33m"
    COLOR_BLUE="\033[1;34m"
    COLOR_MAGENTA="\033[1;35m"
    COLOR_CYAN="\033[1;36m"
    COLOR_WHITE="\033[1;37m"
    COLOR_GRAY="\033[0;90m"
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_BLUE=""
    COLOR_MAGENTA=""
    COLOR_CYAN=""
    COLOR_WHITE=""
    COLOR_GRAY=""
fi

# ===========================
# LOGGING FUNCTIONS
# ===========================

# Initialize logging
init_logging() {
    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    log "INFO" "Logging initialized: $LOG_FILE"
}

# Logging function with improved formatting
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Format level with fixed width for alignment
    local formatted_level=$(printf "%-7s" "$level")
    
    echo "[$timestamp] [$formatted_level] $message" >> "$LOG_FILE"
}

# ===========================
# OUTPUT FORMATTING FUNCTIONS
# ===========================

# Print section header
print_header() {
    local title="$1"
    echo ""
    echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}" | tee -a "$LOG_FILE"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}$title${COLOR_RESET}" | tee -a "$LOG_FILE"
    echo -e "${COLOR_CYAN}${COLOR_BOLD}==========================================${COLOR_RESET}" | tee -a "$LOG_FILE"
    log "INFO" "--- $title ---"
}

# Print success message
print_success() {
    local message="$1"
    echo -e "${COLOR_GREEN}✓ $message${COLOR_RESET}"
    log "SUCCESS" "$message"
}

# Print error message and exit
print_error() {
    local message="$1"
    echo -e "${COLOR_RED}${COLOR_BOLD}✗ ERROR: $message${COLOR_RESET}" >&2
    log "ERROR" "$message"
    exit 1
}

# Print info message
print_info() {
    local message="$1"
    # Check if this is a dry-run message
    if [[ "$message" == *"[DRY-RUN]"* ]] || [[ "$message" == *"DRY-RUN MODE"* ]]; then
        echo -e "${COLOR_MAGENTA}$message${COLOR_RESET}"
    else
        echo -e "${COLOR_BLUE}$message${COLOR_RESET}"
    fi
    log "INFO" "$message"
}

# Print warning message
print_warning() {
    local message="$1"
    echo -e "${COLOR_YELLOW}⚠ WARNING: $message${COLOR_RESET}"
    log "WARNING" "$message"
}

# Print step separator for better log readability
print_step() {
    local step_num="$1"
    local total_steps="$2"
    local description="$3"
    echo ""
    echo -e "${COLOR_WHITE}${COLOR_BOLD}[$step_num/$total_steps] $description${COLOR_RESET}"
    log "STEP" "[$step_num/$total_steps] $description"
}

# ===========================
# AWS VALIDATION FUNCTIONS
# ===========================

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
# STATE MANAGEMENT SYSTEM
# ===========================

# Source state functions (S3-first state management, session management)
source "${SCRIPT_DIR}/state_functions.sh"
