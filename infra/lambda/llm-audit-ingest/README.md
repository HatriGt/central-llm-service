# `llm-audit-ingest` Lambda

Consumes audit documents written to S3 by the LLM backend and stores structured summaries in DynamoDB.

## Environment Variables

- `TABLE_NAME` (required) – DynamoDB table name (`CentralLLMAudit`).
- `MAX_PREVIEW_CHARS` (optional) – number of characters kept inline (default `2048`).

## Deployment Cheat Sheet

```bash
zip -j dist.zip handler.py
aws lambda create-function \
  --function-name llm-audit-ingest \
  --runtime python3.12 \
  --role arn:aws:iam::<ACCOUNT_ID>:role/llm-audit-ingest-role \
  --handler handler.lambda_handler \
  --timeout 60 \
  --environment Variables={TABLE_NAME=CentralLLMAudit,MAX_PREVIEW_CHARS=2048} \
  --zip-file fileb://dist.zip

aws lambda add-permission \
  --function-name llm-audit-ingest \
  --statement-id AllowS3Invoke \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::central-llm-audit \
  --source-account <ACCOUNT_ID>

aws s3api put-bucket-notification-configuration \
  --bucket central-llm-audit \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [
      {
        "LambdaFunctionArn": "arn:aws:lambda:eu-central-1:<ACCOUNT_ID>:function:llm-audit-ingest",
        "Events": ["s3:ObjectCreated:Put"],
        "Filter": {
          "Key": {
            "FilterRules": [{"Name": "prefix", "Value": "logs"}]
          }
        }
      }
    ]
  }'
```

See `docs/audit/AUDIT-PIPELINE.md` for the full architecture, IAM policies, and validation steps.

