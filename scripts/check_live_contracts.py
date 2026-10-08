import json
from pathlib import Path
from jsonschema import Draft202012Validator,FormatChecker
ROOT=Path(__file__).resolve().parents[1]
read=lambda p:json.loads((ROOT/p).read_text())
fixtures=read('.local/smoke-views.json')
for key,path in [('snapshots','contracts/ws/snapshot.schema.json'),('events','contracts/ws/view_event.schema.json')]:
    validator=Draft202012Validator(read(path),format_checker=FormatChecker())
    for value in fixtures[key]:validator.validate(value)
    print(f'{len(fixtures[key])} live synthetic {key}: schema valid')
