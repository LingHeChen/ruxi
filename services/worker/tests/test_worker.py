from worker import canonical_hash, build_hint


def test_hash_matches_utf8_sorted_contract():
    assert canonical_hash({"narrative": "线索", "evidence_ids": []}) == canonical_hash({"evidence_ids": [], "narrative": "线索"})
    assert canonical_hash({"narrative": "线索", "evidence_ids": []}) == "5f398bd90c46d2783227dcf8eb62d0517817fe21d95a74d36b2b34171e13dfcf"


def test_worker_only_uses_authorized_template_input():
    result = build_hint({"input": {"template": "检查你已持有的道具。", "own_role": "passenger", "known_clues": []}})
    assert result == {"narrative": "检查你已持有的道具。", "evidence_ids": []}
