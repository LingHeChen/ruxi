import asyncio
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

LIMIT = 524288000
SANDBOX = Path(__file__).with_name('sandbox.py')

async def decode(binary: str, args: list[str], output: Path) -> bytes:
    proc = await asyncio.create_subprocess_exec(sys.executable, str(SANDBOX), binary, *args,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, cwd=output.parent,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TMPDIR": str(output.parent), "LANG": "C.UTF-8"})
    async def bounded(stream):
        data = bytearray()
        while chunk := await stream.read(4096):
            data.extend(chunk)
            if len(data) > 65536: raise ValueError('MEDIA_LOG_LIMIT')
        return bytes(data)
    try:
        stdout, _ = await asyncio.wait_for(asyncio.gather(bounded(proc.stdout), bounded(proc.stderr)), 600)
        await proc.wait()
    except BaseException:
        if proc.returncode is None: proc.kill()
        await proc.wait(); raise
    if proc.returncode != 0: raise ValueError('MEDIA_DECODE_FAILED')
    return stdout

def digest(file: Path) -> str:
    with file.open('rb') as data:
        return hashlib.file_digest(data, 'sha256').hexdigest()

async def upload_outputs(client, job: dict, files: dict[str, Path]) -> list[dict]:
    descriptors = [{'kind': kind, 'size_bytes': file.stat().st_size, 'sha256': digest(file)} for kind, file in files.items()]
    response = await client.post(f'/internal/work/{job["job_id"]}/output-intents', json={
        'attempt': job['attempt'], 'lease_token': job['lease_token'], 'outputs': descriptors})
    response.raise_for_status()
    intents = response.json()['data']['items']
    outputs = []
    for intent in intents:
        target = urlsplit(intent['upload_url'])
        origin = urlsplit(str(client.base_url))
        if (target.scheme, target.netloc) != (origin.scheme, origin.netloc) or not target.path.startswith('/uploads/') or target.query:
            raise ValueError('INVALID_OUTPUT_ORIGIN')
        file = files[intent['kind']]
        async def chunks():
            with file.open('rb') as stream:
                while chunk := stream.read(65536):
                    yield chunk
        r = await client.put(intent['upload_url'], content=chunks(), headers={
            'Content-Type': intent['mime_type'], 'Content-Length': str(file.stat().st_size)}, timeout=600)
        r.raise_for_status()
        metadata = next(d for d in descriptors if d['kind'] == intent['kind'])
        outputs.append({'asset_id': job['input'].get('asset_id'), 'object_key': intent['object_key'],
            'mime_type': intent['mime_type'], 'size_bytes': metadata['size_bytes'], 'sha256': metadata['sha256']})
    return outputs

async def transcode(client, job: dict) -> dict:
    context = job['input']
    size = context['size_bytes']
    if not isinstance(size, int) or not 1 <= size <= LIMIT:
        raise ValueError('INVALID_MEDIA_SIZE')
    with tempfile.TemporaryDirectory(prefix='ruxi-media-') as directory:
        root = Path(directory)
        source = root / 'source.bin'
        total = 0
        async with client.stream('GET', f'/internal/work/{job["job_id"]}/source', headers={
            'X-Work-Attempt': str(job['attempt']), 'X-Lease-Token': job['lease_token']}, timeout=600) as r:
            r.raise_for_status()
            with source.open('xb') as stream:
                async for chunk in r.aiter_bytes(65536):
                    total += len(chunk)
                    if total > size: raise ValueError('MEDIA_SIZE_MISMATCH')
                    stream.write(chunk)
        if total != size or digest(source) != context['sha256']:
            raise ValueError('MEDIA_HASH_MISMATCH')
        raw = await decode('ffprobe', ['-v', 'error', '-protocol_whitelist', 'file,pipe', '-format_whitelist', 'mov,matroska,webm', '-show_entries',
            'format=duration,format_name:stream=codec_type,width,height', '-of', 'json', str(source)], source)
        if len(raw) > 65536: raise ValueError('MEDIA_METADATA_TOO_LARGE')
        metadata = json.loads(raw)
        formats = metadata['format']['format_name'].split(',')
        if context['mime_type'] == 'video/webm' and 'webm' not in formats or context['mime_type'] in ('video/mp4','video/quicktime') and 'mov' not in formats:
            raise ValueError('MEDIA_MIME_MISMATCH')
        duration = round(float(metadata['format']['duration']) * 1000)
        videos = [s for s in metadata['streams'] if s['codec_type'] == 'video']
        if not 1000 <= duration <= 900000 or len(videos) != 1 or not 1 <= videos[0]['width'] <= 4096 or not 1 <= videos[0]['height'] <= 4096:
            raise ValueError('INVALID_MEDIA_DIMENSIONS')
        video, poster, subtitle = root/'video.mp4', root/'poster.jpg', root/'subtitle.vtt'
        await decode('ffmpeg', ['-nostdin', '-v', 'error', '-protocol_whitelist', 'file,pipe', '-format_whitelist', 'mov,matroska,webm', '-threads', '2', '-i', str(source),
            '-map', '0:v:0', '-map', '0:a:0?', '-vf', "scale='min(1280,iw)':-2", '-c:v', 'libx264', '-preset', 'veryfast',
            '-crf', '24', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-threads', '2', '-movflags', '+faststart', '-y', str(video)], video)
        await decode('ffmpeg', ['-nostdin', '-v', 'error', '-protocol_whitelist', 'file,pipe', '-threads', '2', '-i', str(video),
            '-frames:v', '1', '-vf', 'scale=640:-2', '-threads', '2', '-y', str(poster)], poster)
        subtitle.write_text(f'WEBVTT\nNOTE duration_ms={duration}\n\n', encoding='utf-8')
        outputs = await upload_outputs(client, job, {'video': video, 'poster': poster, 'subtitle': subtitle})
        return {'outputs': outputs}
