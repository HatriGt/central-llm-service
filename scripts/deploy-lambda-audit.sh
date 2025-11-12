#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDA_DIR="${ROOT_DIR}/infra/lambda/llm-audit-ingest"
ZIP_PATH="${LAMBDA_DIR}/dist.zip"

FUNCTION_NAME="${FUNCTION_NAME:-llm-audit-ingest}"
REGION="${REGION:-eu-central-1}"

echo ">>> Packaging Lambda from ${LAMBDA_DIR}"
rm -f "${ZIP_PATH}"
(cd "${LAMBDA_DIR}" && zip -q -j dist.zip handler.py)

echo ">>> Deploying ${FUNCTION_NAME} to region ${REGION}"
aws lambda update-function-code \
  --function-name "${FUNCTION_NAME}" \
  --zip-file "fileb://${ZIP_PATH}" \
  --region "${REGION}"

echo ">>> Deployment complete"

