# AWS Resource Automation with Bash Scripts

Automated Bash scripts for creating and managing AWS resources (EC2, Security Groups, S3) using AWS CLI with comprehensive logging, error handling, and S3-backed tamper-resistant resource tracking.

## 📁 Project Structure

```
automate_script/
├── common_functions.sh        # Shared utility functions + S3-first tracking system
├── create_ec2.sh              # EC2 instance automation
├── create_security_group.sh   # Security group automation
├── create_s3_bucket.sh        # S3 bucket automation
├── cleanup_resources.sh       # Resource cleanup automation
├── .script_session_id         # Auto-generated session identifier (gitignored)
├── .resource_tracking.json    # Read-only local tracking cache (synced from S3)
├── logs/                      # Execution logs
└── screenshots/               # Execution screenshots
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
Shared utility functions including:
- **S3-First Tracking System**: Primary tracking data stored in S3 bucket (`automation_state_file-<ACCOUNT_ID>`) with versioning and encryption
- **Read-Only Local Cache**: Local `.resource_tracking.json` file (chmod 444) synced from S3, refreshes automatically when >5 minutes old
- **Session Management**: Unique session IDs for resource isolation
- **Logging & Error Handling**: Comprehensive logging with timestamps
- **AWS Validation**: Region selection and credential verification

**Tracking Architecture:**
- S3 bucket is the source of truth (versioned, encrypted, per-account isolation)
- Local file is read-only backup that auto-syncs from S3
- Prevents local tampering - any changes overwritten by S3 sync
- Timestamped backups stored in S3 for audit trail

### 🖥️ create_ec2.sh
Creates EC2 instance with key pair, tags it with `Project=AutomationLab` and unique `ScriptManaged` session ID, saves to tracking system (S3 + local), outputs instance ID, public IP, and SSH connection command.

```bash
./create_ec2.sh
# Output: Instance ID, Public IP, SSH command
# Tracking: Saved to S3 and synced to local read-only file
```

![EC2 Instance Creation](screenshots/EC2_shot.png)

### 🔐 create_security_group.sh
Creates security group with SSH (port 22) and HTTP (port 80) access, saves to tracking system, displays security group ID and rules.

```bash
./create_security_group.sh
# Output: Security Group ID, configured rules
# Tracking: Saved to S3 and synced to local read-only file
```

![Security Group Creation](screenshots/Sec_group_shot.png)

### 🪣 create_s3_bucket.sh
Creates uniquely named S3 bucket with versioning enabled, uploads `welcome.txt`, saves to tracking system, and generates pre-signed URL.

```bash
./create_s3_bucket.sh
# Output: Bucket name, versioning status, pre-signed URL
# Tracking: Saved to S3 tracking bucket and synced to local read-only file
```

![S3 Bucket Creation](screenshots/S3_Bucket.png)

### 🧹 cleanup_resources.sh
Safely deletes resources using two-level filtering (`Project=AutomationLab` + `ScriptManaged` session ID). Only deletes script-created resources, protecting manual/developer resources. 

**Cleanup Process:**
1. Syncs latest tracking data from S3
2. Terminates EC2 instances and deletes key pairs
3. Removes security groups
4. Empties and deletes S3 buckets created by scripts
5. **Deletes tracking S3 bucket** (after all resources cleaned)
6. Removes local read-only tracking file
7. Cleans up local files (.pem keys, welcome.txt)

```bash
./cleanup_resources.sh
# Warning: Permanently deletes resources and tracking infrastructure!
```

![Cleanup Resources](screenshots/Clean_resources%20.png.png)

## 📝 Usage

```bash
# Create resources (automatically tracked in S3 + local)
./create_security_group.sh
./create_s3_bucket.sh
./create_ec2.sh

# View tracked resources (syncs from S3)
cat .resource_tracking.json

# Cleanup when done (removes everything including tracking infrastructure)
./cleanup_resources.sh
```

## 🔒 Resource Tracking & Safety

**S3-First Tracking System:**
- **Primary Source**: S3 bucket `script-tracking-backup-<ACCOUNT_ID>`
  - Versioning enabled for audit trail
  - AES256 encryption at rest
  - Public access blocked
  - Per-account isolation
- **Local Cache**: `.resource_tracking.json` (read-only, chmod 444)
  - Auto-syncs from S3 every 5 minutes
  - Prevents tampering - any local changes overwritten by S3
  - Format: JSON with session IDs and resource details

**Session Management:** 
- Scripts automatically track resources using `.script_session_id` file
- Each session has unique ID (format: `automation-YYYYMMDD-HHMMSS-RANDOM`)
- Cleanup only deletes resources with matching session ID tag
- Protects manual/developer resources from accidental deletion
- Delete `.script_session_id` to start a fresh session

**Safety Features:**
- Two-level filtering: `Project=AutomationLab` + `ScriptManaged=<session_id>`
- Confirmation prompt before destructive operations
- Manual resources without script tags are never deleted
- Complete audit trail via S3 versioning and timestamped backups

**Screenshots:** See [screenshots/](screenshots/) directory for execution examples

**Logs:** All executions logged to `./logs/` directory with timestamps

## 🛠️ Troubleshooting

- **Permission Denied:** Run `chmod +x *.sh`
- **AWS Credentials:** Run `aws configure` and verify with `aws sts get-caller-identity`
- **Resource Failures:** Check IAM permissions, AWS quotas, and logs in `./logs/`
- **Region Issues:** Ensure AMI availability in selected region
- **Tracking Sync Issues:** Check S3 bucket permissions and network connectivity
- **Read-Only File Errors:** Tracking file is intentionally read-only (chmod 444) - modifications only via scripts
