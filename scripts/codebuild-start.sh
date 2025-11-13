#!/bin/bash

set -euo pipefail

PROJECT_NAME="${CODEBUILD_PROJECT:-llama31-8b-vllm-build}"
REGION="${REGION:-eu-central-1}"

echo ">>> Starting CodeBuild project ${PROJECT_NAME} in ${REGION}"
aws codebuild start-build \
  --project-name "${PROJECT_NAME}" \
  --region "${REGION}"

