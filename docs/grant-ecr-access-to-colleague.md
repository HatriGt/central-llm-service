# Grant ECR Access to Colleague

This guide explains how to give your colleague access to view and pull Docker images from your AWS ECR repository.

## Prerequisites

- ✅ Your colleague has an AWS account
- ✅ You have IAM permissions to create and attach policies
- ✅ You know your colleague's AWS account ID or IAM username

## Option 1: Same AWS Account (Recommended)

If your colleague is in the **same AWS account**, create an IAM policy for them.

### Step 1: Create IAM Policy for Read-Only Access

Create a file `ecr-readonly-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ],
      "Resource": "arn:aws:ecr:eu-central-1:396360117331:repository/mistral8b-vllm"
    }
  ]
}
```

### Step 2: Create the Policy in AWS

```bash
# Create the policy
aws iam create-policy \
  --policy-name ECRReadOnly-Mistral8B \
  --policy-document file://ecr-readonly-policy.json \
  --description "Read-only access to Mistral 8B ECR repository"
```

### Step 3: Attach Policy to Your Colleague's User

```bash
# Replace with your colleague's IAM username
COLLEAGUE_USERNAME="john.doe"

# Get the policy ARN (from step 2 output, or use this command)
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='ECRReadOnly-Mistral8B'].Arn" --output text)

# Attach the policy to the user
aws iam attach-user-policy \
  --user-name ${COLLEAGUE_USERNAME} \
  --policy-arn ${POLICY_ARN}
```

### Step 4: (Alternative) Attach Policy to a Group

If your colleague is part of a group:

```bash
# Create a group (if doesn't exist)
aws iam create-group --group-name ecr-users

# Attach policy to group
aws iam attach-group-policy \
  --group-name ecr-users \
  --policy-arn ${POLICY_ARN}

# Add user to group
aws iam add-user-to-group \
  --user-name ${COLLEAGUE_USERNAME} \
  --group-name ecr-users
```

## Option 2: Different AWS Account (Cross-Account Access)

If your colleague is in a **different AWS account**, use repository policies.

### Step 1: Get Your Colleague's AWS Account ID

Ask your colleague to run:
```bash
aws sts get-caller-identity --query "Account" --output text
```

### Step 2: Set ECR Repository Policy

Create `ecr-cross-account-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCrossAccountPull",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::COLLEAGUE_ACCOUNT_ID:root"
      },
      "Action": [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:DescribeImages",
        "ecr:DescribeRepositories",
        "ecr:ListImages"
      ]
    }
  ]
}
```

**Replace** `COLLEAGUE_ACCOUNT_ID` with your colleague's AWS account ID.

### Step 3: Apply Repository Policy

```bash
# Replace COLLEAGUE_ACCOUNT_ID with actual account ID
sed -i 's/COLLEAGUE_ACCOUNT_ID/123456789012/g' ecr-cross-account-policy.json

# Apply the policy
aws ecr set-repository-policy \
  --repository-name mistral8b-vllm \
  --policy-text file://ecr-cross-account-policy.json \
  --region eu-central-1
```

### Step 4: Your Colleague's Setup (Their Side)

Your colleague needs to create this policy in **their AWS account**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:eu-central-1:396360117331:repository/mistral8b-vllm"
    }
  ]
}
```

## Option 3: Full Access (Push & Pull)

If you want to give your colleague **full access** to push images too:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:*"
      ],
      "Resource": "arn:aws:ecr:eu-central-1:396360117331:repository/mistral8b-vllm"
    }
  ]
}
```

Then follow the same steps as Option 1 to create and attach the policy.

## Verify Access

Ask your colleague to test access:

```bash
# Login to ECR
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin \
  396360117331.dkr.ecr.eu-central-1.amazonaws.com

# List images in repository
aws ecr describe-images \
  --repository-name mistral8b-vllm \
  --region eu-central-1

# Pull the image
docker pull 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
```

## Instructions to Send to Your Colleague

Send them this message:

---

### 📧 Email Template for Colleague

**Subject:** Access to Mistral 8B ECR Docker Image

Hi [Colleague Name],

I've granted you access to our Mistral 8B ECR repository. Here's how to pull and run the image:

**1. Login to ECR:**
```bash
aws ecr get-login-password --region eu-central-1 | \
  docker login --username AWS --password-stdin \
  396360117331.dkr.ecr.eu-central-1.amazonaws.com
```

**2. Pull the image:**
```bash
docker pull 396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
```

**3. Run locally (with GPU):**
```bash
docker run -d \
  --name ministral-llm \
  --gpus all \
  -p 8000:8000 \
  396360117331.dkr.ecr.eu-central-1.amazonaws.com/mistral8b-vllm:latest
```

**4. Test the API:**
```bash
curl http://localhost:8000/health
```

**Repository Details:**
- Region: `eu-central-1`
- Repository: `mistral8b-vllm`
- Image Size: ~30GB
- GPU Required: Yes (24GB VRAM recommended)

Let me know if you have any issues!

---

## Troubleshooting

### Issue: "no basic auth credentials"
**Solution:** Make sure to run the ECR login command first

### Issue: "AccessDeniedException"
**Solution:** 
1. Verify the IAM policy is attached: `aws iam list-attached-user-policies --user-name USERNAME`
2. Check if the policy has the correct permissions
3. Ensure the resource ARN matches your ECR repository

### Issue: "RepositoryPolicyNotFoundException"
**Solution:** Repository policy doesn't exist yet. Use `aws ecr set-repository-policy` to create it.

## Security Best Practices

1. **✅ Principle of Least Privilege:** Only grant read-only access unless push access is needed
2. **✅ Specific Resources:** Use specific repository ARNs instead of `"Resource": "*"`
3. **✅ Time-Limited Access:** Consider creating temporary credentials for external contractors
4. **✅ Audit Regularly:** Review who has access periodically
5. **✅ MFA Required:** Enable MFA for users with ECR access

## Revoke Access

To revoke access later:

```bash
# Detach the policy from user
aws iam detach-user-policy \
  --user-name ${COLLEAGUE_USERNAME} \
  --policy-arn ${POLICY_ARN}

# Or remove from group
aws iam remove-user-from-group \
  --user-name ${COLLEAGUE_USERNAME} \
  --group-name ecr-users
```

## Quick Reference

| Access Level | Use Case | Policy |
|--------------|----------|--------|
| Read-Only | View and pull images | `ECRReadOnly-Mistral8B` |
| Full Access | Push and pull images | `ECRFullAccess-Mistral8B` |
| Cross-Account | Different AWS account | Repository Policy |

## Additional Resources

- [AWS ECR User Guide](https://docs.aws.amazon.com/ecr/)
- [ECR Repository Policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-policies.html)
- [IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)

