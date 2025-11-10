import json
import os
from datetime import datetime, timezone
from typing import Any, Dict, Optional

import boto3
from botocore.exceptions import ClientError

DDB_TABLE_NAME = os.environ["TABLE_NAME"]
MAX_PREVIEW_CHARS = int(os.environ.get("MAX_PREVIEW_CHARS", "2048"))

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(DDB_TABLE_NAME)


def lambda_handler(event: Dict[str, Any], _context) -> Dict[str, Any]:
    """Process S3-created audit documents and persist them into DynamoDB."""
    results = {"processed": 0, "written": 0, "skipped": 0, "errors": 0}

    for record in event.get("Records", []):
        if record.get("eventSource") != "aws:s3":
            continue

        results["processed"] += 1
        bucket = record["s3"]["bucket"]["name"]
        key = record["s3"]["object"]["key"]

        try:
            audit_doc = _load_audit_document(bucket, key)
            if not audit_doc:
                results["skipped"] += 1
                continue

            item = _parse_audit_document(audit_doc, bucket, key)
            if not item:
                results["skipped"] += 1
                continue

            _write_audit_record(item)
            results["written"] += 1
        except Exception as exc:  # noqa: BLE001
            results["errors"] += 1
            print(f"[WARN] Failed to ingest s3://{bucket}/{key}: {exc}")

    return results


def _load_audit_document(bucket: str, key: str) -> Optional[Dict[str, Any]]:
    try:
        response = s3_client.get_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        print(f"[WARN] Unable to load audit object s3://{bucket}/{key}: {exc}")
        return None

    body = response["Body"].read()
    try:
        return json.loads(body.decode("utf-8"))
    except json.JSONDecodeError as exc:
        print(f"[WARN] Invalid JSON in audit object s3://{bucket}/{key}: {exc}")
        return None


def _parse_audit_document(document: Dict[str, Any], bucket: str, key: str) -> Optional[Dict[str, Any]]:
    request_id = _clean_value(document.get("requestId"))
    if not request_id:
        return None

    headers = {str(k).lower(): str(v) for k, v in document.get("headers", {}).items()}
    project = _clean_value(headers.get("x-llm-source"))
    if not project:
        return None

    user_id = _clean_value(headers.get("x-llm-user"))
    request_type = _clean_value(headers.get("x-llm-request-type"))
    latency = _safe_int(document.get("latencyMs"))
    status_code = _safe_int(document.get("statusCode"))
    iso_ts = _normalize_timestamp(document.get("timestamp"))

    request_preview = document.get("requestBodyPreview")
    response_preview = document.get("responseBodyPreview")
    if request_preview is None and "requestBody" in document:
        request_preview = _build_preview(document["requestBody"])
    if response_preview is None and "responseBody" in document:
        response_preview = _build_preview(document["responseBody"])

    project_key = f"project#{project}"

    item: Dict[str, Any] = {
        "id": project_key,
        "createdAt": f"{iso_ts}#{request_id}",
        "timestamp": iso_ts,
        "requestId": request_id,
        "projectId": project,
        "userId": user_id,
        "requestType": request_type,
        "statusCode": status_code,
        "latencyMs": latency,
        "promptPreview": request_preview,
        "responsePreview": response_preview,
        "auditBucket": bucket,
        "auditObjectKey": key,
    }

    # Secondary indexes
    if user_id:
        item["userIdPk"] = f"user#{user_id}"
        item["userIdSk"] = f"{iso_ts}#{request_id}"
    if status_code is not None:
        item["statusPk"] = f"status#{status_code}"
        item["statusSk"] = f"{iso_ts}#{project}#{request_id}"
    if latency is not None:
        item["latencyPk"] = project_key

    return item


def _build_preview(payload: Any) -> Optional[str]:
    try:
        text = payload if isinstance(payload, str) else json.dumps(payload)
    except (TypeError, ValueError):
        return None
    text = text.strip()
    if len(text) <= MAX_PREVIEW_CHARS:
        return text
    return text[:MAX_PREVIEW_CHARS]


def _write_audit_record(item: Dict[str, Any]) -> None:
    table.put_item(Item={k: v for k, v in item.items() if v is not None})


def _clean_value(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        trimmed = value.strip()
        if (
            not trimmed
            or trimmed == "-"
            or trimmed.lower() == "null"
            or trimmed.startswith("--")
        ):
            return None
        if trimmed.startswith("-(") and "header.get(" in trimmed:
            return None
        return trimmed
    return str(value)


def _safe_int(value: Any) -> Optional[int]:
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _normalize_timestamp(value: Any) -> str:
    if isinstance(value, str) and value:
        try:
            # Attempt to parse ISO 8601 strings
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed.astimezone(timezone.utc).isoformat(timespec="milliseconds")
        except ValueError:
            pass
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")

