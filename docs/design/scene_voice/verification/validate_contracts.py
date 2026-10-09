from pathlib import Path
import json,copy,re,csv
from jsonschema import Draft202012Validator,FormatChecker
from datetime import datetime
fc=FormatChecker()
@fc.checks("date-time", raises=(ValueError,TypeError))
def rfc3339(v):
 if not isinstance(v,str):return True
 if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})",v):return False
 return datetime.fromisoformat(v.replace("Z","+00:00")).tzinfo is not None
P=Path(__file__).resolve().parents[1];S=json.loads((P/'contracts/voice.schema.json').read_text());W=json.loads((P/'examples/wire.json').read_text());checks=[]
def check(n,v):
 checks.append({'name':n,'status':'PASS' if v else 'FAIL'})
 if not v:raise AssertionError(n)
def valid(name,x):return not list(Draft202012Validator({'$ref':'#/$defs/'+name,'$defs':S['$defs']},format_checker=fc).iter_errors(x))
Draft202012Validator.check_schema(S)
for name,value in W.items():check('有效样例 '+name,valid(name,value))
for action,body in [('grant',{}),('heartbeat',{'lease_id':W['Grant']['lease_id']}),('renew',{'lease_id':W['Grant']['lease_id']}),('client_state',{'lease_id':W['Grant']['lease_id'],'status':'connected'})]:
 x=copy.deepcopy(W['Request']);x.update(action=action,body=body);check('请求变体 '+action,valid('Request',x))
for field,value in [('location_id','hidden'),('rtc_room_id','guessed'),('member_id','other'),('token','unexpected')]:
 x=copy.deepcopy(W['Request']);x['body'][field]=value;check('拒绝客户端字段 '+field,not valid('Request',x))
x=copy.deepcopy(W['Request']);x['voice_protocol_version']=2;check('拒绝未知语音协议',not valid('Request',x))
x=copy.deepcopy(W['Grant']);x['token_expires_at']='tomorrow';check('拒绝非标准时间',not valid('Grant',x))
x=copy.deepcopy(W['State']);x['status']='teleport';check('拒绝未知状态',not valid('State',x))
policy=json.loads((P/'contracts/policy.schema.json').read_text());fixture=json.loads((P/'examples/policy.json').read_text());check('DSL增量样例',Draft202012Validator(policy).is_valid(fixture));fixture['communication']['voice']['scope']='global';check('拒绝全局语音',not Draft202012Validator(policy).is_valid(fixture))
for action,body in [('restrict_member',{'member_id':'m1'}),('release_member',{'member_id':'m1'}),('retry_retirement',{'transition_id':W['Request']['request_id']}),('disable_room',{})]:check('管理动作 '+action,valid('AdminRequest',{'request_id':W['Request']['request_id'],'action':action,'reason':'测试处置','body':body}))
check('举报样例',valid('Report',{'request_id':W['Request']['request_id'],'target_member_id':'peer','reason_code':'noise'}))
x={'request_id':W['Request']['request_id'],'target_member_id':'peer','reason_code':'noise','audio':'forbidden'};check('举报不接受音频上传',not valid('Report',x))
A=json.loads((P/'contracts/openapi.json').read_text())
def refs(x):
 if isinstance(x,dict):
  if '$ref' in x:yield x['$ref']
  for v in x.values():yield from refs(v)
 elif isinstance(x,list):
  for v in x:yield from refs(v)
for ref in refs(A):check('OpenAPI引用 '+ref,ref.split('/')[-1] in S['$defs'])
C=json.loads((P/'examples/config.json').read_text());check('封禁覆盖全部有效凭证与时钟裕量',C['retire_ban_seconds']>=C['token_ttl_seconds']+C['clock_margin_seconds']);check('心跳早于租约到期',C['heartbeat_seconds']<C['lease_ttl_seconds']);check('续签提前量小于Token有效期',C['renew_before_seconds']<C['token_ttl_seconds']);check('默认不采集且后台不保活',not C['default_mic_enabled'] and not C['background_voice_enabled'])
rows=list(csv.DictReader((P/'verification/coverage.csv').open()));ids={v['id'] for v in json.loads((P/'verification/acceptance.json').read_text())};check('覆盖表测试编号均可定位',all(set(re.findall('VA[0-9]+',r['验收']))<=ids for r in rows));check('全部18集成用例保持未执行',len(ids)==18 and all(x['status']=='NOT_RUN' for x in json.loads((P/'verification/acceptance.json').read_text())))
check('原型不使用网络和麦克风',not re.search(r'getUserMedia|new WebSocket|fetch\(', (P/'prototype/voice.html').read_text()))
(P/'verification/contract_results.json').write_text(json.dumps({'checks':checks,'scope':'附件结构与参数约束，非后端实现验证'},ensure_ascii=False,indent=2));print('PASS',len(checks))
