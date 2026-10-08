import asyncio
import json
import httpx
from adapters import ModelConfig
from editor_adapter import propose

def context(): return {'target': ['title'], 'original': '原文', 'instruction': '润色', 'max_length': 500}
def test_edit_fallback_is_an_inert_original_text_proposal():
    p = asyncio.run(propose(ModelConfig('template', '', '', ''), context()))
    assert p['suggested'] == '原文'
    assert p['target'] == ['title']
    assert p['source'] == 'template'

def test_edit_adapter_never_gives_the_model_control_of_targets_or_rules():
    def handler(request):
        body = json.loads(request.content)
        assert 'target' not in json.loads(body['messages'][1]['content'])
        return httpx.Response(200, json={'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps({'suggested': '新文案', 'notes': []})}}]})
    p = asyncio.run(propose(ModelConfig('deepseek', 'https://api.deepseek.com', 'test', 'synthetic'), context(), httpx.MockTransport(handler)))
    assert p['target'] == ['title'] and p['suggested'] == '新文案' and p['source'] == 'ai'

def test_edit_adapter_rejects_rule_patches_and_falls_back():
    def handler(_): return httpx.Response(200, json={'choices': [{'finish_reason': 'stop', 'message': {'content': json.dumps({'suggested': '文案', 'notes': [], 'graph': {}})}}]})
    p = asyncio.run(propose(ModelConfig('deepseek', 'https://api.deepseek.com', 'test', 'synthetic'), context(), httpx.MockTransport(handler)))
    assert p['source'] == 'template' and p['suggested'] == '原文'
