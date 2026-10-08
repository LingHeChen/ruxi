from worker import canonical_hash, build_hint


def test_hash_matches_utf8_sorted_contract():
    assert canonical_hash({"narrative": "线索", "evidence_ids": []}) == canonical_hash({"evidence_ids": [], "narrative": "线索"})
    assert canonical_hash({"narrative": "线索", "evidence_ids": []}) == "5f398bd90c46d2783227dcf8eb62d0517817fe21d95a74d36b2b34171e13dfcf"


def test_worker_only_uses_authorized_template_input():
    result = build_hint({"input": {"template": "检查你已持有的道具。", "own_role": "passenger", "known_clues": []}})
    assert result == {"narrative": "检查你已持有的道具。", "evidence_ids": []}


def test_revoked_lease_cancels_decoder_without_completing(monkeypatch):
    import asyncio
    import httpx
    import pytest
    import worker
    cancelled = []
    posts = []
    async def revoked(client, job):
        await asyncio.sleep(0)
        request = httpx.Request('POST', 'http://core.test/heartbeat')
        raise httpx.HTTPStatusError('lease revoked', request=request, response=httpx.Response(403, request=request))
    async def decoder(client, job):
        try: await asyncio.sleep(60)
        finally: cancelled.append(True)
    async def post(client, path, body): posts.append(path)
    monkeypatch.setattr(worker, 'heartbeat', revoked)
    monkeypatch.setattr(worker, 'transcode', decoder)
    monkeypatch.setattr(worker, 'post', post)
    with pytest.raises(httpx.HTTPStatusError):
        asyncio.run(worker.process(None, {'kind':'media_transcode','job_id':'synthetic-job'}))
    assert cancelled == [True]
    assert posts == []
