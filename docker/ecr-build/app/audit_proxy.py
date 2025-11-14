import asyncio
import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict

import boto3
import httpx
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOGGER = logging.getLogger(__name__)

VLLM_HOST = os.environ.get("VLLM_HOST", "127.0.0.1")
VLLM_PORT = int(os.environ.get("VLLM_PORT", "8001"))
PROXY_HOST = os.environ.get("PROXY_HOST", "0.0.0.0")
PROXY_PORT = int(os.environ.get("PROXY_PORT", "8000"))
MODEL_PATH = os.environ.get("MODEL_PATH", "/app/models/Llama-3.1-8B-Instruct/")
AUDIT_BUCKET = os.environ.get("AUDIT_BUCKET")
AUDIT_PREFIX = os.environ.get("AUDIT_PREFIX", "logs")
AWS_REGION = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "eu-central-1"))
MAX_BODY_PREVIEW = int(os.environ.get("AUDIT_BODY_PREVIEW", "2048"))
VLLM_READY_TIMEOUT = int(os.environ.get("VLLM_READY_TIMEOUT", "600"))  # 10 minutes default (8B model loads faster than 11B vision)

app = FastAPI()
_http_client: httpx.AsyncClient | None = None
_vllm_process: subprocess.Popen | None = None
_s3_client = None


def _create_s3_client():
    if not AUDIT_BUCKET:
        return None
    session_kwargs: Dict[str, Any] = {}
    if AWS_REGION:
        session_kwargs["region_name"] = AWS_REGION
    return boto3.client("s3", **session_kwargs)


def _read_vllm_output(process: subprocess.Popen) -> None:
    """Read vLLM subprocess output and log it."""
    if process.stdout is None:
        return
    try:
        for line in iter(process.stdout.readline, b""):
            if not line:
                break
            line_text = line.decode("utf-8", errors="replace").rstrip()
            if line_text:
                LOGGER.info("[vLLM] %s", line_text)
    except Exception as exc:
        LOGGER.exception("Error reading vLLM output: %s", exc)
    finally:
        LOGGER.info("vLLM output reader thread finished")


def start_vllm_process() -> subprocess.Popen:
    args = [
        sys.executable,
        "-m",
        "vllm.entrypoints.openai.api_server",
        "--model",
        MODEL_PATH,
        "--host",
        "0.0.0.0",
        "--port",
        str(VLLM_PORT),
        "--served-model-name",
        os.environ.get("SERVED_MODEL_NAME", "llama-3.1-8b-instruct"),
        "--max-model-len",
        os.environ.get("MAX_MODEL_LEN", "32768"),
        "--gpu-memory-utilization",
        os.environ.get("GPU_MEMORY_UTILIZATION", "0.92"),
        "--trust-remote-code",
        # Batching optimizations for 30 concurrent users + large contexts
        "--max-num-seqs",
        os.environ.get("MAX_NUM_SEQS", "64"),  # 2x user count + buffer
        "--max-num-batched-tokens",
        os.environ.get("MAX_NUM_BATCHED_TOKENS", "40960"),  # Must be >= MAX_MODEL_LEN (32768), higher for batching multiple large requests
        # Block size optimization for large contexts
        "--block-size",
        os.environ.get("BLOCK_SIZE", "16"),
        # Prefix caching (helps with repeated prompts)
        "--enable-prefix-caching",
        # Keep logging enabled (you need logs)
    ]

    LOGGER.info("Starting vLLM server with args: %s", args)
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=1)
    
    # Start background thread to read and log vLLM output
    output_thread = threading.Thread(target=_read_vllm_output, args=(process,), daemon=True)
    output_thread.start()
    LOGGER.info("Started vLLM output reader thread")
    
    return process


def stop_vllm_process():
    global _vllm_process
    if _vllm_process and _vllm_process.poll() is None:
        LOGGER.info("Stopping vLLM subprocess")
        _vllm_process.send_signal(signal.SIGTERM)
        try:
            _vllm_process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            LOGGER.warning("vLLM subprocess did not terminate in time; killing")
            _vllm_process.kill()


def _safe_json(data: bytes | str) -> Any:
    try:
        text = data.decode("utf-8") if isinstance(data, bytes) else data
        return json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def _preview_text(text: str) -> str:
    if len(text) <= MAX_BODY_PREVIEW:
        return text
    return text[:MAX_BODY_PREVIEW]


def _build_audit_record(request_id: str, headers: Dict[str, str], request_body: bytes, response_body: bytes, status_code: int, latency_ms: int) -> Dict[str, Any]:
    request_body_text = request_body.decode("utf-8", errors="replace")
    response_body_text = response_body.decode("utf-8", errors="replace")

    record: Dict[str, Any] = {
        "requestId": request_id,
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "headers": headers,
        "statusCode": status_code,
        "latencyMs": latency_ms,
        "requestBodyPreview": _preview_text(request_body_text),
        "responseBodyPreview": _preview_text(response_body_text),
    }

    request_json = _safe_json(request_body)
    response_json = _safe_json(response_body)
    if request_json is not None:
        record["requestBody"] = request_json
    if response_json is not None:
        record["responseBody"] = response_json
    return record


def _put_audit_record(record: Dict[str, Any]) -> None:
    if not AUDIT_BUCKET:
        LOGGER.debug("AUDIT_BUCKET not set; skipping audit publish")
        return
    global _s3_client
    if _s3_client is None:
        _s3_client = _create_s3_client()
    if _s3_client is None:
        LOGGER.warning("S3 client unavailable; skipping audit publish")
        return

    request_id = record["requestId"]
    prefix = AUDIT_PREFIX.rstrip("/")
    key = f"{prefix}/{datetime.now(timezone.utc).strftime('%Y/%m/%d')}/{request_id}.json"
    try:
        _s3_client.put_object(
            Bucket=AUDIT_BUCKET,
            Key=key,
            Body=json.dumps(record).encode("utf-8"),
            ContentType="application/json",
        )
        LOGGER.info("Wrote audit record to s3://%s/%s", AUDIT_BUCKET, key)
    except (BotoCoreError, ClientError) as exc:
        LOGGER.exception("Failed to write audit record to S3: %s", exc)


async def wait_for_vllm_ready(timeout: int | None = None) -> None:
    if timeout is None:
        timeout = VLLM_READY_TIMEOUT
    url = f"http://{VLLM_HOST}:{VLLM_PORT}/health"
    LOGGER.info("Waiting for vLLM server readiness at %s (timeout: %d seconds)", url, timeout)
    start = time.time()
    last_status_log = start
    check_interval = 2
    status_log_interval = 60  # Log status every 60 seconds
    
    async with httpx.AsyncClient(timeout=5.0) as client:
        while time.time() - start < timeout:
            # Check if vLLM process is still running
            if _vllm_process is not None:
                return_code = _vllm_process.poll()
                if return_code is not None:
                    elapsed = int(time.time() - start)
                    raise RuntimeError(
                        f"vLLM process exited unexpectedly with code {return_code} "
                        f"(waited {elapsed} seconds). Check logs for details."
                    )
            
            # Try health check
            try:
                resp = await client.get(url)
                if resp.status_code == 200:
                    elapsed = int(time.time() - start)
                    LOGGER.info("vLLM server is ready (took %d seconds)", elapsed)
                    return
            except Exception:  # noqa: BLE001
                pass
            
            # Log progress periodically
            now = time.time()
            if now - last_status_log >= status_log_interval:
                elapsed = int(now - start)
                remaining = timeout - elapsed
                LOGGER.info(
                    "Still waiting for vLLM... (elapsed: %d seconds, remaining: %d seconds, "
                    "process running: %s)",
                    elapsed,
                    remaining,
                    _vllm_process.poll() is None if _vllm_process else "N/A",
                )
                last_status_log = now
            
            await asyncio.sleep(check_interval)
        
        elapsed = int(time.time() - start)
        process_status = "running" if _vllm_process and _vllm_process.poll() is None else "stopped"
        raise RuntimeError(
            f"vLLM server did not become ready in time (waited {elapsed} seconds, "
            f"process status: {process_status}). Check logs for vLLM output."
        )


@app.on_event("startup")
async def on_startup():
    global _http_client
    _http_client = httpx.AsyncClient(
        base_url=f"http://{VLLM_HOST}:{VLLM_PORT}",
        timeout=None,
        limits=httpx.Limits(
            max_connections=100,  # High for 30 concurrent users
            max_keepalive_connections=20  # Keep connections alive
        )
    )


@app.on_event("shutdown")
async def on_shutdown():
    global _http_client
    if _http_client is not None:
        await _http_client.aclose()
        _http_client = None
    stop_vllm_process()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    if _http_client is None:
        return JSONResponse(status_code=503, content={"message": "Backend not ready"})

    body = await request.body()
    headers = {k: v for k, v in request.headers.items()}
    request_id = headers.get("x-request-id", str(uuid.uuid4()))

    filtered_headers = {k: v for k, v in headers.items() if k.lower() != "host"}

    LOGGER.info("Forwarding request %s to vLLM", request_id)
    start = time.perf_counter()
    try:
        resp = await _http_client.post(
            "/v1/chat/completions",
            content=body,
            headers=filtered_headers,
        )
    except httpx.HTTPError as exc:
        LOGGER.exception("Request %s failed when forwarding to vLLM: %s", request_id, exc)
        return JSONResponse(status_code=502, content={"message": "Upstream vLLM error"})

    latency_ms = int((time.perf_counter() - start) * 1000)
    audit_record = _build_audit_record(request_id, headers, body, resp.content, resp.status_code, latency_ms)
    _put_audit_record(audit_record)

    proxy_headers = [(k, v) for k, v in resp.headers.items() if k.lower() not in {"content-length", "transfer-encoding", "connection"}]
    return Response(content=resp.content, status_code=resp.status_code, headers=dict(proxy_headers), media_type=resp.headers.get("content-type"))


def main():
    global _vllm_process
    _vllm_process = start_vllm_process()
    loop = asyncio.get_event_loop()
    try:
        loop.run_until_complete(wait_for_vllm_ready())
    except Exception:  # noqa: BLE001
        LOGGER.exception("vLLM failed to initialize; terminating")
        stop_vllm_process()
        sys.exit(1)

    import uvicorn

    LOGGER.info("Starting audit proxy on %s:%s", PROXY_HOST, PROXY_PORT)
    uvicorn.run(
        app,
        host=PROXY_HOST,
        port=PROXY_PORT,
        log_config=None,  # Use our custom logging
        workers=1,  # Single worker (vLLM handles concurrency)
        loop="uvloop",  # Faster event loop
        access_log=False  # Disable uvicorn access log (we have audit)
    )


if __name__ == "__main__":
    main()
