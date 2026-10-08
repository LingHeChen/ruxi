import json
from pathlib import Path
import pytest
from jsonschema import Draft202012Validator, FormatChecker, ValidationError
ROOT=Path(__file__).resolve().parents[3]

def load(path):return json.loads((ROOT/path).read_text())

def test_command_positive_and_forged_actor_negative():
    v=Draft202012Validator(load('contracts/ws/command.schema.json'),format_checker=FormatChecker())
    v.validate(load('contracts/fixtures/command.valid.json'))
    with pytest.raises(ValidationError):v.validate(load('contracts/fixtures/command.invalid.json'))

def test_content_sample_is_machine_valid():
    Draft202012Validator(load('contracts/content/sample.schema.json')).validate(load('content/demo/story.json'))
    Draft202012Validator(load('contracts/content/graph.schema.json'),format_checker=FormatChecker()).validate(load('content/demo/story.json'))

def test_every_schema_itself_is_valid():
    for p in (ROOT/'contracts').rglob('*.schema.json'):
        Draft202012Validator.check_schema(json.loads(p.read_text()))

@pytest.mark.parametrize('fixture',load('contracts/fixtures/golden.json'))
def test_golden_vote_paths(fixture):
    priority=['leave','wait','publish'] if 'C3' in fixture['shared'] else ['leave','wait']
    counts={o:fixture['votes'].count(o) for o in priority}
    winner=max(priority,key=lambda o:counts[o])
    assert {'leave':'E3','wait':'E2','publish':'E1'}[winner]==fixture['ending']
