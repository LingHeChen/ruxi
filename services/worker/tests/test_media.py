import asyncio
import hashlib
from pathlib import Path
import httpx
import pytest
from media_pipeline import transcode, decode

def test_child_tools_cannot_inherit_vendor_secrets(monkeypatch, tmp_path):
    captured = {}
    class Process:
        returncode = 0
        def __init__(self):
            self.stdout = asyncio.StreamReader()
            self.stderr = asyncio.StreamReader()
        async def wait(self): return 0
    async def spawn(*args, **kwargs):
        captured.update(kwargs)
        process = Process()
        process.stdout.feed_eof(); process.stderr.feed_eof()
        return process
    monkeypatch.setenv('DEEPSEEK_API_KEY', 'synthetic-private-canary')
    monkeypatch.setattr(asyncio, 'create_subprocess_exec', spawn)
    asyncio.run(decode('ffprobe', [], tmp_path/'source.bin'))
    assert set(captured['env']) == {'PATH', 'TMPDIR', 'LANG'}
    assert 'DEEPSEEK_API_KEY' not in captured['env']

@pytest.mark.parametrize('body', [b'not-a-video', b'\x00'*1024])
def test_bad_content_never_produces_ready_outputs(body):
    job = {'job_id':'test-job','attempt':1,'lease_token':'synthetic', 'input':{'size_bytes':len(body),'sha256':hashlib.sha256(body).hexdigest(),'mime_type':'video/mp4'}}
    requests=[]
    def handler(request):
        requests.append(request)
        return httpx.Response(200, content=body)
    async def run():
        async with httpx.AsyncClient(base_url='http://core.test',transport=httpx.MockTransport(handler)) as client:
            with pytest.raises(ValueError, match='MEDIA_DECODE_FAILED'):
                await transcode(client, job)
    asyncio.run(run())
    assert len(requests)==1
    assert requests[0].method=='GET'
