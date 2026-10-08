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

load_dotenv(Path(__file__).with_name('.env'), override=False)
CORE_URL = os.environ.get("CORE_URL", "http://localhost:4000")
WORKER_TOKEN = os.environ.get("WORKER_TOKEN", "local-worker-change-me")
WORKER_ID = os.environ.get("WORKER_ID", "local-hint-worker")
stats = {"accepted": 0, "ignored": 0, "errors": 0}
model_config = ModelConfig.from_env()
adapter = build_adapter(model_config)


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
        result = await adapter.hint(job["input"])
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
    finally:
        beat.cancel()
        try:
            await beat
        except asyncio.CancelledError:
            pass


async def loop():
    async with httpx.AsyncClient(base_url=CORE_URL, timeout=10, trust_env=False, headers={
        "Authorization": f"Bearer {WORKER_TOKEN}", "X-Work-Protocol": "1"}) as client:
        while True:
            try:
                job = await post(client, "/internal/work/claim", {
                    "worker_id": WORKER_ID, "supported_kinds": ["player_hint"], "claim_id": str(uuid.uuid4())})
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
