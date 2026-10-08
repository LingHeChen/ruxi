"""Least-privilege worker: no database connection and no room state writes."""
import asyncio
import hashlib
import json
import os
import uuid
from pathlib import Path
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI
from dotenv import load_dotenv
from adapters import ModelConfig, build_adapter
from media_pipeline import transcode
from editor_adapter import edit

load_dotenv(Path(__file__).with_name('.env'), override=False)
CORE_URL = os.environ.get("CORE_URL", "http://localhost:4000")
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "local-worker-change-me")
WORKER_ID = os.environ.get("WORKER_ID", "local-hint-worker")
stats = {"accepted": 0, "ignored": 0, "errors": 0}
model_config = ModelConfig.from_env()
adapter = build_adapter(model_config)
SUPPORTED_KINDS = os.environ.get('SUPPORTED_KINDS', 'player_hint,editor_ai,media_transcode').split(',')
if not SUPPORTED_KINDS or any(kind not in ('player_hint', 'editor_ai', 'media_transcode') for kind in SUPPORTED_KINDS):
    raise ValueError('invalid supported task kinds')


def canonical_hash(result: dict) -> str:
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(encoded.encode()).hexdigest()


def build_hint(job: dict) -> dict:
    # Deterministic baseline. A vendor adapter can replace this only after evals.
    # Core marks the result template when it matches the supplied fallback.
    # This adapter performs no vendor/model calls.
    return {"narrative": job["input"]["template"], "evidence_ids": []}


async def post(client: httpx.AsyncClient, path: str, payload: dict) -> dict:
    r = await client.post(path, json=payload)
    r.raise_for_status()
    if r.status_code == 204:
        return {"job_id": None}
    return r.json()["data"]


async def heartbeat(client: httpx.AsyncClient, job: dict):
    while True:
        await asyncio.sleep(15)
        await post(client, f'/internal/work/{job["job_id"]}/heartbeat', {
            "attempt": job["attempt"], "lease_token": job["lease_token"]})


async def process(client: httpx.AsyncClient, job: dict):
    beat = asyncio.create_task(heartbeat(client, job))
    try:
        async def compute():
            if job['kind'] == 'player_hint': return await adapter.hint(job['input'])
            if job['kind'] == 'editor_ai': return await edit(client, job, model_config)
            if job['kind'] == 'media_transcode': return await transcode(client, job)
            raise ValueError('unsupported job kind')
        computation = asyncio.create_task(compute())
        done, _ = await asyncio.wait({beat, computation}, return_when=asyncio.FIRST_COMPLETED)
        if beat in done:
            await beat  # A lost/revoked lease interrupts computation and never commits outputs.
        result = await computation
        body = {"attempt": job["attempt"], "lease_token": job["lease_token"],
                "result_hash": canonical_hash(result), "result": result}
        # Lost responses retry exactly the same completed attempt/hash.
        for retry in range(3):
            try:
                reply = await post(client, f'/internal/work/{job["job_id"]}/complete', body)
                stats[reply["status"]] += 1
                return
            except httpx.TransportError:
                if retry == 2:
                    raise
                await asyncio.sleep(2 ** retry)
    except (ValueError, KeyError, OSError) as error:
        code = str(error) if str(error).isupper() and len(str(error)) <= 64 else 'PROCESSING_FAILED'
        await post(client, f'/internal/work/{job["job_id"]}/fail', {
            'attempt': job['attempt'], 'lease_token': job['lease_token'], 'code': code, 'retryable': False})
        stats['errors'] += 1
    finally:
        beat.cancel()
        if 'computation' in locals():
            computation.cancel()
            await asyncio.gather(beat, computation, return_exceptions=True)
        else:
            await asyncio.gather(beat, return_exceptions=True)


async def loop():
    async with httpx.AsyncClient(base_url=CORE_URL, timeout=10, trust_env=False, headers={
        "Authorization": f"Bearer {WORKER_TOKEN}", "X-Work-Protocol": "1"}) as client:
        while True:
            try:
                job = await post(client, "/internal/work/claim", {
                    "worker_id": WORKER_ID, "supported_kinds": SUPPORTED_KINDS, "claim_id": str(uuid.uuid4())})
                if job.get("job_id"):
                    await process(client, job)
                else:
                    await asyncio.sleep(1)
            except (httpx.HTTPError, ValueError, KeyError):
                stats["errors"] += 1
                await asyncio.sleep(2)


@asynccontextmanager
async def lifespan(_app):
    task = asyncio.create_task(loop())
    yield
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Ruxi internal worker", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok", "mode": model_config.provider,
            "model_configured": bool(model_config.api_key), "stats": stats}
