from pathlib import Path
import json,copy
from jsonschema import Draft202012Validator
from reference_engine import Engine,semantic_errors
P=Path(__file__).parent.parent
results=[]
def check(name,ok,detail=''):
 results.append({'name':name,'status':'PASS' if ok else 'FAIL','detail':detail});assert ok,(name,detail)
s=json.loads((P/'examples/restaurant.json').read_text());schema=json.loads((P/'contracts/story.schema.json').read_text());v=Draft202012Validator(schema);v.check_schema(schema)
check('schema valid restaurant',not list(v.iter_errors(s)) and not semantic_errors(s))
for f in P.glob('examples/invalid_*.json'):
 data=json.loads(f.read_text());errs=list(v.iter_errors(data))+semantic_errors(data);check('reject '+f.name,bool(errs),str(errs[0])[:150])
e=Engine(s)
for a in ['ask','move:dining_hall','unlock','move:hall_kitchen','switch_off']:e.resolve({'guest':a})
check('preset route reaches safe ending',e.ending=='safe');(P/'examples/golden_safe_trace.json').write_text(json.dumps(e.trace,ensure_ascii=False,indent=2))
e=Engine(s)
for _ in range(4):e.resolve({})
check('fourth round fallback',e.ending=='evacuated' and e.round==4)
e=Engine(s);e.resolve({'guest':'inspect','doctor':'ask'});check('personal knowledge isolation','stain' not in e.visible('doctor')['known'] and 'access' not in e.visible('guest')['known'])
e=Engine(s);before=e.actors['guest']['ap'];e.resolve({'guest':'switch_off'});check('invalid location does not charge',e.actors['guest']['ap']==before)
e=Engine(s)
for a in ['move:dining_hall','take_tool','pass','force_door','move:hall_kitchen','switch_off']:e.resolve({'guest':a})
check('free template alternative route',e.ending=='safe' and e.world['noise'])
e=Engine(s);e.resolve({r:'move:dining_hall' for r in e.actors});e.resolve({r:'take_tool' for r in e.actors});owners=[r for r,a in e.actors.items() if 'fire_extinguisher' in a['inventory']];check('one owner and rotating priority',owners==['doctor'])
w=json.loads((P/'examples/wire.json').read_text());pv=Draft202012Validator(json.loads((P/'contracts/protocol.schema.json').read_text()));check('Phoenix envelope and payload',len(w['command'])==5 and not list(pv.iter_errors(w['command'][4])))
bad=copy.deepcopy(w['command'][4]);bad['body']['effects']=[];check('reject injected effects',bool(list(pv.iter_errors(bad))))
# repeat complete play from independent engine and compare expected world outcomes
for _ in range(5):
 e=Engine(s)
 for a in ['ask','move:dining_hall','unlock','move:hall_kitchen','switch_off']:e.resolve({'guest':a})
 assert e.ending=='safe'
check('deterministic replay five runs',True)
(P/'verification/contract_results.json').write_text(json.dumps({'checks':results,'limitations':['参考引擎不包含数据库、WS、概率判定、AI、并发进程或媒体服务。']},ensure_ascii=False,indent=2))
print(json.dumps(results,ensure_ascii=False,indent=2))
