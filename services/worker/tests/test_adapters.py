import asyncio
import json

import httpx
import pytest

from adapters import ChatCompletionAdapter, ModelConfig, TemplateAdapter, validate_hint

CONTEXT = {"own_role": "investigator", "known_clues": ["C1"], "public_clues": [],
           "clue_details": [{"clue_id": "C1", "text": "只允许这条记录。"}],
           "hint_level": 1, "template": "查看自己的调查点。",
           "world_state": {"C3": "canary-secret"}, "access_token": "canary-token"}


def reply(value, status=200, reason="stop"):
    return httpx.Response(status, json={"choices": [{"finish_reason": reason,
        "message": {"content": json.dumps(value, ensure_ascii=False)}}]})


def run_handler(handler):
    config = ModelConfig("deepseek", "https://api.deepseek.com", "configured-model", "test-only-key")
    return asyncio.run(ChatCompletionAdapter(config, httpx.MockTransport(handler)).hint(CONTEXT))


def test_deepseek_transport_is_authorized_json_only():
    def handler(request):
        body = json.loads(request.content)
        assert str(request.url) == "https://api.deepseek.com/chat/completions"
        assert request.headers["authorization"] == "Bearer test-only-key"
        assert body["response_format"] == {"type": "json_object"}
        assert body["thinking"] == {"type": "disabled"}
        assert b"canary-secret" not in request.content
        assert b"canary-token" not in request.content
        assert "world_state" not in body["messages"][1]["content"]
        return reply({"narrative": "对照你掌握的记录。", "evidence_ids": ["C1"]})
    assert run_handler(handler)["evidence_ids"] == ["C1"]


@pytest.mark.parametrize("value", [
    {"narrative": "未知秘密", "evidence_ids": ["C3"]},
    {"narrative": "合法文本", "evidence_ids": [], "state_patch": {"ending": "E1"}},
    {"narrative": "", "evidence_ids": []},
    {"narrative": "x" * 2001, "evidence_ids": []},
    {"narrative": "引用重复", "evidence_ids": ["C1", "C1"]},
])
def test_bad_output_falls_back_without_mutating_game(value):
    assert run_handler(lambda _: reply(value)) == {"narrative": CONTEXT["template"], "evidence_ids": []}


@pytest.mark.parametrize("status", [429, 500, 503])
def test_vendor_errors_fall_back_without_retries(status):
    calls = []
    def handler(request):
        calls.append(request)
        return reply({}, status)
    assert run_handler(handler)["narrative"] == CONTEXT["template"]
    assert len(calls) == 1


def test_timeout_truncation_and_missing_key_fall_back():
    def timeout(request):
        raise httpx.ReadTimeout("timeout", request=request)
    assert run_handler(timeout)["narrative"] == CONTEXT["template"]
    assert run_handler(lambda _: reply({}, reason="length"))["narrative"] == CONTEXT["template"]
    no_key = ModelConfig("deepseek", "https://api.deepseek.com", "model", "")
    assert asyncio.run(ChatCompletionAdapter(no_key).hint(CONTEXT))["narrative"] == CONTEXT["template"]
    assert asyncio.run(TemplateAdapter().hint(CONTEXT))["narrative"] == CONTEXT["template"]


def test_config_rejects_redirect_credentials_and_insecure_endpoints(monkeypatch):
    monkeypatch.setenv("MODEL_PROVIDER", "deepseek")
    for url in ["http://api.deepseek.com", "https://user:pass@api.deepseek.com", "https://api.deepseek.com?token=secret"]:
        monkeypatch.setenv("MODEL_BASE_URL", url)
        with pytest.raises(ValueError):
            ModelConfig.from_env()


def test_default_deepseek_and_compatible_provider_configuration(monkeypatch):
    for key in ["MODEL_PROVIDER", "MODEL_BASE_URL", "MODEL_NAME", "DEEPSEEK_API_KEY", "MODEL_API_KEY"]:
        monkeypatch.delenv(key, raising=False)
    config = ModelConfig.from_env()
    assert config.provider == "deepseek"
    assert config.base_url == "https://api.deepseek.com"
    assert config.model and not config.api_key
    monkeypatch.setenv("MODEL_PROVIDER", "openai_compatible")
    monkeypatch.setenv("MODEL_BASE_URL", "https://example.test/v1")
    monkeypatch.setenv("MODEL_NAME", "configured-model")
    monkeypatch.setenv("MODEL_API_KEY", "compatible-key")
    compatible = ModelConfig.from_env()
    assert compatible.model == "configured-model"
    assert compatible.api_key == "compatible-key"
