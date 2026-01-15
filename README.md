# AWS Resource Automation with Bash Scripts

Automated Bash scripts for creating and managing AWS resources (EC2, Security Groups, S3) using AWS CLI with comprehensive logging, error handling, dry-run mode, and S3-backed tamper-resistant resource tracking.

## ✨ Key Features

- 🚀 **Automated Resource Creation**: EC2, S3, Security Groups with one command
- 🔍 **Dry-Run Mode**: Preview changes before creating resources
- 🔐 **S3-First State Management**: Primary state in S3 with local read-only cache
- 🎯 **Session-Based Tracking**: Safe cleanup with unique session identifiers
- 📊 **Comprehensive Logging**: Structured logs with aligned formatting
- 🛡️ **Safety Mechanisms**: Two-level filtering prevents accidental deletions
- 🏗️ **Modular Architecture**: Clean separation of utility and state functions

## 📁 Project Structure

```
automate_script/
├── common_functions.sh          # Utility functions (logging, formatting, AWS validation)
├── state_functions.sh           # S3-first state management system
├── create_ec2.sh               # EC2 instance automation (with --dry-run)
├── create_security_group.sh    # Security group automation
├── create_s3_bucket.sh         # S3 bucket automation (with --dry-run)
├── cleanup_resources.sh        # Resource cleanup automation (with --dry-run)
├── .resource_state.json        # State file with session + resources (read-only)
├── logs/                       # Execution logs with timestamps
└── screenshots/                # Execution screenshots
```

## 🚀 Quick Setup

### 1. Install & Configure AWS CLI
```bash
# Install AWS CLI (Linux/macOS)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Configure credentials
aws configure

# Verify
aws sts get-caller-identity
```

![AWS Configuration](screenshots/Config_shot.png)

### 2. Setup Scripts
```bash
cd automate_script
chmod +x *.sh
```

**Prerequisites:** AWS account with EC2, S3, and IAM permissions

## 📖 Scripts Overview

### 🔧 common_functions.sh
Central utility functions including:
- **Logging**: Structured logs with aligned columns and timestamps
- **Output Formatting**: Color-coded console messages with symbols (✓, ✗, ⚠)
- **AWS Validation**: Credential verification and region selection
- **Error Handling**: Graceful error management with proper exit codes
- **Sources**: state_functions.sh for state management

### 🗄️ state_functions.sh
S3-first state management system:
- **Primary Storage**: S3 bucket `automation-state-file-<ACCOUNT_ID>`
  - Versioning enabled for change history
  - AES256 encryption at rest
  - Public access blocked
  - Per-account isolation
- **Local Cache**: `.resource_state.json` (chmod 444, read-only)
  - Auto-syncs from S3 when >5 minutes old
  - Prevents tampering - overwrites local changes with S3 data
- **Session Management**: Automatic session ID generation and tracking
- **State Structure**:
  ```json
  {
    "version": "1.0",
    "current_session": "automation-20260115-103000-12345",
    "sessions": {
      "automation-20260115-103000-12345": {
        "created_at": "2026-01-15T10:30:00Z",
        "resources": {
          "ec2_instance": [...],
          "s3_bucket": [...],
          "key_pair": [...],
          "security_group": [...]
        }
      }
    }
  }
  ```

### 🖥️ create_ec2.sh
Creates EC2 instance with automatic tracking and tagging.

**Usage:**
```bash
# Dry-run (preview without creating)
./create_ec2.sh --dry-run

# Create resources
./create_ec2.sh
```

**Features:**
- Automatically selects latest Amazon Linux 2023 AMI
- Creates EC2 key pair and saves locally (chmod 400)
- Launches t3.micro instance with proper tags
- Tags: `Project=AutomationLab`, `ScriptManaged=<session_id>`
- Saves to state file and uploads to S3
- Outputs: Instance ID, Public IP, SSH command

![EC2 Instance Creation](screenshots/EC2_shot.png)

### 🔐 create_security_group.sh
Creates security group with SSH and HTTP access.

**Usage:**
```bash
./create_security_group.sh
```

**Features:**
- Creates security group in default VPC
- Adds ingress rules: SSH (port 22), HTTP (port 80)
- Tags with session ID for safe cleanup
- Tracks in state file and S3

![Security Group Creation](screenshots/Sec_group_shot.png)

### 🪣 create_s3_bucket.sh
Creates S3 bucket with versioning and encryption.

**Usage:**
```bash
# Dry-run (preview without creating)
./create_s3_bucket.sh --dry-run

# Create bucket
./create_s3_bucket.sh
```

**Features:**
- Generates unique bucket name with timestamp
- Enables versioning and encryption
- Uploads sample file (welcome.txt)
- Applies lifecycle policies
- Tags with session ID
- Tracks in state file and S3

![S3 Bucket Creation](screenshots/S3_Bucket.png)

### 🧹 cleanup_resources.sh
Safely deletes all script-created resources.

**Usage:**
```bash
# Dry-run (preview what would be deleted)
./cleanup_resources.sh --dry-run

# Delete resources
./cleanup_resources.sh
```

**Cleanup Process:**
1. Syncs latest state from S3
2. Loads session ID from state file
3. Shows confirmation prompt with resource list
4. Terminates EC2 instances (waits for termination)
5. Deletes key pairs (+ local .pem files)
6. Removes security groups
7. Empties and deletes S3 buckets
8. Deletes state S3 bucket
9. Removes local state file
10. Cleans local files (.pem keys, welcome.txt)

**Safety Features:**
- Two-level filtering: `Project=AutomationLab` + `ScriptManaged=<session_id>`
- Confirmation prompt (type 'yes' to proceed)
- Only deletes script-managed resources
- Manual resources remain untouched
- Dry-run mode to preview deletions

![Cleanup Resources](screenshots/Clean_resources%20.png.png)

## 📝 Usage Examples

### Basic Workflow

```bash
# 1. Preview EC2 creation (dry-run)
./create_ec2.sh --dry-run

# 2. Create EC2 instance
./create_ec2.sh

# 3. Create S3 bucket (with dry-run first)
./create_s3_bucket.sh --dry-run
./create_s3_bucket.sh

# 4. Create security group
./create_security_group.sh

# 5. View current state
cat .resource_state.json | jq .

# 6. Preview cleanup (dry-run)
./cleanup_resources.sh --dry-run

# 7. Cleanup everything
./cleanup_resources.sh
```

### Advanced Usage

```bash
# Check current session
jq -r '.current_session' .resource_state.json

# List all resources for current session
jq '.sessions[.current_session].resources' .resource_state.json

# Start fresh session (delete state file, next run creates new session)
rm .resource_state.json
./create_ec2.sh

# Multi-region cleanup
./cleanup_resources.sh  # Select "All regions" option
```

## 🔒 Resource Tracking & Safety

### Session Management

**Automatic Session Creation:**
- Session ID generated on first run: `automation-YYYYMMDD-HHMMSS-PID`
- Stored in `.resource_state.json` under `current_session` field
- All subsequent runs reuse same session until cleanup
- New session created after cleanup completes

**Session Lifecycle:**
```
Run 1: create_ec2.sh
  └─> No state file → Create session: automation-20260115-103000-12345

Run 2: create_s3_bucket.sh  
  └─> State exists → Reuse session: automation-20260115-103000-12345

Run 3: cleanup_resources.sh
  └─> Delete all resources + state file

Run 4: create_ec2.sh
  └─> No state file → Create NEW session: automation-20260116-090000-67890
```

### State File Structure

**Single Source of Truth:**
- Primary: S3 bucket `automation-state-file-<ACCOUNT_ID>/state.json`
- Cache: Local `.resource_state.json` (chmod 444, read-only)
- Format: JSON with session tracking

### Safety Features

**Two-Level Filtering:**
1. **Level 1**: `Project=AutomationLab` tag
2. **Level 2**: `ScriptManaged=<session_id>` tag

**Protection:**
- Manual resources (no ScriptManaged tag) → Never deleted
- Other sessions (different session ID) → Never deleted
- Only YOUR session resources → Deleted

**Dry-Run Mode:**
```bash
# Preview what would be created
./create_ec2.sh --dry-run
./create_s3_bucket.sh --dry-run

# Preview what would be deleted
./cleanup_resources.sh --dry-run
```

### Development/Testing
```bash
# Quick environment setup
./create_ec2.sh
./create_s3_bucket.sh

# Test application
# ...

# Clean up costs
./cleanup_resources.sh
```

### CI/CD Integration
```bash
# Preview in pipeline
./create_ec2.sh --dry-run

# Create test environment
./create_ec2.sh
./create_s3_bucket.sh

# Run tests
# ...

# Auto-cleanup
./cleanup_resources.sh
```

### Learning/Demonstration
```bash
# Show students what would be created
./create_ec2.sh --dry-run

# Create actual resources
./create_ec2.sh

# Demonstrate state tracking
cat .resource_state.json | jq .

# Safe cleanup
./cleanup_resources.sh
```

## 📚 Additional Resources

**Screenshots:** See [screenshots/](screenshots/) directory for execution examples

**Logs:** All executions logged to `./logs/` directory with timestamps

