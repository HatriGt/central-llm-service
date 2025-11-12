# Snapshot, AMI, and Launch Template Runbook

This guide captures the exact AWS CLI flow we used to freeze a pre-warmed vLLM environment (Docker image already pulled), register it as an AMI, and wire it into a launch template for faster spin-ups.

---

## Prerequisites

1. AWS CLI configured with permissions for EC2, ECS, and tagging APIs.
2. Working vLLM POC already launched once via `docs/WORKING-POC-GUIDE.md`.
3. ECS cluster/service: `central-llm-service-cluster` / `central-llm-service`.
4. IAM instance profile: `ecsInstanceRole`; SSH key: `central-llm-key`.
5. Security group: `sg-01348191cf1b4bc37` (adjust if yours differs).
6. Most recent g6e.2xlarge hourly price verified (per cost-awareness rule).

> **Note:** Replace IDs if your environment differs. Shown values match the session that produced snapshot `snap-04d5095fae1bfaca0`.

---

## Step-by-Step Snapshot Capture

### 1. Drain ECS tasks

```bash
aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 0 \
  --region eu-central-1

aws ecs wait services-stable \
  --cluster central-llm-service-cluster \
  --services central-llm-service \
  --region eu-central-1
```

### 2. Stop the GPU instance

```bash
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=central-llm-ec2" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region eu-central-1
aws ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" --region eu-central-1
```

### 3. Capture the root volume ID

```bash
VOLUME_ID=$(aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --region eu-central-1 \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/xvda`].Ebs.VolumeId | [0]' \
  --output text)
```

### 4. Create and tag the snapshot

```bash
SNAP_ID=$(aws ec2 create-snapshot \
  --volume-id "${VOLUME_ID}" \
  --description "central-llm-vllm-cache" \
  --region eu-central-1 \
  --query 'SnapshotId' \
  --output text)

aws ec2 create-tags \
  --resources "${SNAP_ID}" \
  --region eu-central-1 \
  --tags Key=Name,Value=central-llm-vllm-snapshot

aws ec2 wait snapshot-completed --snapshot-ids "${SNAP_ID}" --region eu-central-1
```

---

## Register a Reusable AMI

### 5. Register the AMI from the snapshot

```bash
AMI_ID=$(aws ec2 register-image \
  --region eu-central-1 \
  --name central-llm-vllm-ami-$(date +%Y%m%d) \
  --root-device-name /dev/xvda \
  --architecture x86_64 \
  --virtualization-type hvm \
  --block-device-mappings "[
    {
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {
        \"SnapshotId\": \"${SNAP_ID}\",
        \"VolumeSize\": 100,
        \"VolumeType\": \"gp3\",
        \"DeleteOnTermination\": true
      }
    }
  ]" \
  --query 'ImageId' \
  --output text)
```

### 6. Tag the AMI

```bash
aws ec2 create-tags \
  --region eu-central-1 \
  --resources "${AMI_ID}" \
  --tags Key=Name,Value=central-llm-vllm-ami
```

Verify the mapping:

```bash
aws ec2 describe-images \
  --region eu-central-1 \
  --image-ids "${AMI_ID}" \
  --query 'Images[0].BlockDeviceMappings[0]'
```

---

## Create a Launch Template

### 7. Base64 encode the ECS GPU user data

```bash
cat <<'EOF' | base64
#!/bin/bash
echo ECS_CLUSTER=central-llm-service-cluster >> /etc/ecs/ecs.config
echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
EOF
```

Save the encoded string for the next command (example shown below).

### 8. Create the template

```bash
aws ec2 create-launch-template \
  --region eu-central-1 \
  --launch-template-name central-llm-launch-template \
  --version-description "vLLM pre-cached AMI" \
  --launch-template-data "{
    \"ImageId\": \"${AMI_ID}\",
    \"InstanceType\": \"g6e.2xlarge\",
    \"IamInstanceProfile\": {\"Name\": \"ecsInstanceRole\"},
    \"KeyName\": \"central-llm-key\",
    \"SecurityGroupIds\": [\"sg-01348191cf1b4bc37\"],
    \"UserData\": \"IyEvYmluL2Jhc2gKZWNobyBFQ1NfQ0xVU1RFUj1jZW50cmFsLWxsbS1zZXJ2aWNlLWNsdXN0ZXIgPj4gL2V0Yy9lY3MvZWNzLmNvbmZpZwplY2hvIEVDU19FTkFCTEVfR1BVX1NVUFBPUlQ9dHJ1ZSA+PiAvZXRjL2Vjcy9lY3MuY29uZmlnCg==\"
  }"
```

List versions any time you update:

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-name central-llm-launch-template \
  --region eu-central-1
```

---

## Cleanup After Image Capture

Once the AMI and template exist, terminate the staging instance so you only pay for the snapshot and ECR storage.

```bash
aws ec2 terminate-instances --instance-ids "${INSTANCE_ID}" --region eu-central-1
aws ec2 wait instance-terminated --instance-ids "${INSTANCE_ID}" --region eu-central-1
```

Confirm the root volume has been deleted:

```bash
aws ec2 describe-volumes \
  --filters "Name=volume-id,Values=${VOLUME_ID}" \
  --region eu-central-1
```

---

## Launching with the Template

When you need the API online:

```bash
aws ec2 run-instances \
  --region eu-central-1 \
  --launch-template LaunchTemplateName=central-llm-launch-template \
  --count 1

aws ecs update-service \
  --cluster central-llm-service-cluster \
  --service central-llm-service \
  --desired-count 1 \
  --region eu-central-1
```

Wait for `Running:1` before hitting the API.

---

## Refreshing the Image Later

1. Launch from the template, let the new Docker image download.
2. Repeat the snapshot steps to capture the refreshed cache.
3. Register a new AMI and set it as the latest launch template version.
4. Delete superseded snapshots/AMIs to avoid double-charging.

This workflow keeps spin-up time low while paying only for ECR + snapshot storage when idle.


