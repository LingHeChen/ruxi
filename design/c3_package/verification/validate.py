"""验证设计附件，不是生产引擎测试。运行：python verification/validate.py"""
from pathlib import Path
import json,copy,unicodedata
from jsonschema import Draft202012Validator
P=Path(__file__).resolve().parents[1]; results=[]
def record(name,condition):
 results.append({'name':name,'status':'PASS' if condition else 'FAIL'})
def load(p):return json.loads((P/p).read_text())
s=load('contracts/extension.schema.json'); e=load('examples/extension.json'); v=Draft202012Validator(s)
record('增量 profile 通过形状校验',not list(v.iter_errors(e)))
bad=copy.deepcopy(e);bad['interactions'][1]['kind']='combat';record('本期拒绝战斗互动',bool(list(v.iter_errors(bad))))
bad=copy.deepcopy(e);bad['interactions'][1]['base_target']=101;record('拒绝超界概率',bool(list(v.iter_errors(bad))))
bad=copy.deepcopy(e);bad['interactions'][1]['modifiers'][0]['visibility']='secret';record('拒绝隐藏概率修正',bool(list(v.iter_errors(bad))))
v2=Draft202012Validator(load('contracts/commands.schema.json'));wire=load('examples/wire.json')
for k in ['password','check']:record(k+'命令形状有效',not list(v2.iter_errors(wire[k])))
bad=copy.deepcopy(wire['check']);bad['body']['input']['roll']=1;record('拒绝客户端骰子点数',bool(list(v2.iter_errors(bad))))
for target in [0,1,60,100]:record('1d100阈值 '+str(target),sum(r<=target for r in range(1,101))==target)
record('前导零保留','0427'!='427')
record('规范化示例',unicodedata.normalize('NFKC',' ＡBc ').strip().casefold()=='abc')
# 最小参考状态机仅覆盖并发重复与共享尝试，不用于产品执行。
def execute(state,key,answer):
 if key in state['receipts']:
  old=state['receipts'][key];return old['outcome'] if old['answer']==answer else 'IDEMPOTENCY_CONFLICT'
 if state['solved'] or state['used']>=3:return 'invalidated'
 state['used']+=1;state['ap']-=1;state['solved']=answer=='0427'
 out='success' if state['solved'] else 'failure';state['receipts'][key]={'answer':answer,'outcome':out};return out
state={'used':0,'ap':3,'solved':False,'receipts':{}};execute(state,'a','0000');execute(state,'a','0000');record('重复命令不重复计次扣费',state['used']==1 and state['ap']==2)
record('同命令异参拒绝',execute(state,'a','0427')=='IDEMPOTENCY_CONFLICT')
execute(state,'b','0000');execute(state,'c','0000');record('共享最后机会耗尽后不再执行',execute(state,'d','0427')=='invalidated' and state['ap']==0)
state={'used':0,'ap':3,'solved':False,'receipts':{}};execute(state,'a','0427');record('解锁后排队猜测失效不扣费',execute(state,'b','0000')=='invalidated' and state['ap']==2)
# 答案仅为测试输入，不包含在玩家 wire result / quote 中。
for k in ['quote_check','private_result','map_patch']:record(k+'无答案字段','0427' not in json.dumps(wire[k]) and 'answer' not in json.dumps(wire[k]))
(P/'verification/contract_results.json').write_text(json.dumps({'checks':results,'limitations':['参考状态机仅为附件语义实验','无真实DB WS CSPRNG或权限验证']},ensure_ascii=False,indent=2))
print(json.dumps(results,ensure_ascii=False));assert all(r['status']=='PASS' for r in results)
