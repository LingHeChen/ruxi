"""Generate the reviewed C1 machine contracts. Do not infer requests from responses."""
import json
from pathlib import Path
from content_schema import graph_schema
ROOT=Path(__file__).resolve().parents[1]

def write(path,data):
    p=ROOT/path
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')

UUID={'type':'string','format':'uuid'}
INT={'type':'integer','minimum':0,'maximum':9007199254740991}
CODE={'type':'string','pattern':'^[A-Za-z0-9_:-]{1,64}$'}
TEXT={'type':'string','maxLength':500,'minLength':1}
BOOL={'type':'boolean'}
def obj(props,required=None):
    return {'type':'object','properties':props,'required':list(props) if required is None else required,'additionalProperties':False}

payloads={
 'select_role':{'role_code':CODE},'ready':{'ready':BOOL},'start':{},
 'media_complete':{'media_id':CODE,'media_epoch':INT,'mode':{'enum':['video','summary']}},'confirm_exploration_end':{},'request_pause':{},
 'confirm_pause':{'pause_request_id':UUID},'cancel_pause':{'pause_request_id':UUID},'resume':{'timer_generation':INT},'leave_room':{},
 'investigate':{'action_id':CODE},'share_clue':{'clue_id':CODE},'offer_item':{'item_id':CODE,'to_member':UUID},
 'accept_offer':{'offer_id':UUID},'reject_offer':{'offer_id':UUID},'cancel_offer':{'offer_id':UUID},
 'vote':{'round_id':UUID,'option_id':CODE},'request_hint':{'hint_level':{'enum':[1,2]}},'chat_send':{'text':TEXT},
 'request_role_swap':{'to_member':UUID},'accept_role_swap':{'role_swap_id':UUID},'reject_role_swap':{'role_swap_id':UUID},'cancel_role_swap':{'role_swap_id':UUID}}
variants=[]
for kind,props in payloads.items():
    envelope={'protocol_version':{'const':1},'recovery_epoch':{'type':'string','minLength':1},'command_id':UUID,'phase_id':{'anyOf':[UUID,{'type':'null'}]},'control_generation':{**INT,'minimum':1},'type':{'const':kind},'payload':obj(props)}
    if kind=='offer_item':envelope['target_version']={**INT,'minimum':1}
    variants.append(obj(envelope))
write('contracts/ws/command.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema','title':'C1 authoritative command','oneOf':variants})
fields=['room','self','members','public_scene','own_role','own_clues','visible_items','offers','available_actions','own_vote','vote_round','hints','chat','media','collaboration']
event_types=['member_changed','role_selected','ready_changed','room_started','phase_changed','lifecycle_changed','clue_discovered','clue_shared','transfer_offered','transfer_resolved','vote_recorded','vote_settled','hint_pending','hint_ready','hint_failed','chat_added','media_changed','collaboration_changed']
DATE={'type':'string','format':'date-time'}
nullable=lambda s: {'anyOf':[s,{'type':'null'}]}
arr=lambda s,n=100: {'type':'array','items':s,'maxItems':n}
response=lambda p,r=None: {**obj(p,r),'additionalProperties':True}
role=CODE
clue=response({'clue_id':CODE,'title':{'type':'string'},'text':{'type':'string'},'shared':BOOL})
option=response({'option_id':CODE,'label':{'type':'string'}})
display=response({'option_id':CODE,'label':{'type':'string'},'eligible':BOOL,'reason_code':CODE,'reason_text':{'type':'string'}},['option_id','label','eligible'])
ids=arr(UUID,4)
models={
 'room':response({'room_id':UUID,'content_version_id':UUID,'lifecycle':{'enum':['lobby','running','paused','suspended','finished','abandoned']},'phase_id':nullable(UUID),'phase_code':nullable({'enum':['briefing','exploration','decision','ending']}),'exploration_step':{'enum':['active','interlude']},'deadline_at':nullable(DATE),'remaining_ms':nullable(INT),'timer_generation':INT,'host_membership_id':UUID,'ending_code':nullable(CODE)},['room_id','content_version_id','lifecycle','phase_id','phase_code','deadline_at','remaining_ms','timer_generation','host_membership_id']),
 'self':response({'membership_id':UUID,'control_generation':{**INT,'minimum':1},'role_code':nullable(role)}),
 'members':arr(response({'membership_id':UUID,'display_name':{'type':'string'},'role_code':nullable(role),'ready':BOOL,'online':BOOL,'briefing_ready':BOOL}),4),
 'public_scene':response({'title':{'type':'string'},'description':{'type':'string'},'shared_clues':arr(clue)}),
 'own_role':nullable(response({'role_code':role,'title':{'type':'string'},'description':{'type':'string'}})),
 'own_clues':arr(clue),
 'visible_items':arr(response({'item_id':CODE,'title':{'type':'string'},'owner_membership_id':UUID,'version':{**INT,'minimum':1},'transferable':BOOL})),
 'offers':arr(response({'offer_id':UUID,'item_id':CODE,'from_member':UUID,'to_member':UUID,'status':{'enum':['pending','accepted','rejected','cancelled','expired']},'expires_at':DATE})),
 'available_actions':arr(response({'action_id':CODE,'label':{'type':'string'},'enabled':BOOL,'reason_code':CODE},['action_id','label','enabled'])),
 'own_vote':nullable(response({'round_id':UUID,'option_id':CODE})),
 'vote_round':nullable(response({'round_id':UUID,'options':arr(option,10),'display_options':arr(display,10),'status':{'enum':['open','settled']},'deadline_at':nullable(DATE),'tally':{'type':'object','additionalProperties':INT},'winner':CODE},['round_id','options','display_options','status','deadline_at'])),
 'hints':response({'remaining':{'type':'integer','minimum':0,'maximum':2},'pending_job_id':nullable(UUID),'entries':arr(response({'hint_id':UUID,'text':{'type':'string','maxLength':2000},'source':{'enum':['ai','template']}}),2)}),
 'chat':arr(response({'message_id':UUID,'sender_member':UUID,'text':TEXT,'sent_at':DATE}),50),
 'media':response({'authorized':arr(response({'media_id':CODE,'asset_id':UUID,'kind':{'enum':['public','own_role']},'media_epoch':INT}),16),'public_anchor':nullable(response({'media_id':CODE,'media_epoch':INT,'start_at':DATE,'position_ms':INT,'rate':{'enum':[0,1]}}))}),
 'collaboration':response({'media_acks':arr(response({'media_id':CODE,'members':ids}),16),'early_finish_acks':ids,'interlude_acks':ids,'resume_acks':ids,'manual_pause_used':BOOL,'pause_request':nullable(response({'id':UUID,'expires_at':DATE,'confirmed_members':ids})),'role_swap':nullable(response({'id':UUID,'from_member':UUID,'to_member':UUID,'from_role_code':role,'to_role_code':role,'status':{'enum':['pending','accepted','rejected','cancelled','expired']},'expires_at':DATE}))})
}
write('contracts/ws/snapshot.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**response(models)})
write('contracts/ws/view_event.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**obj({'protocol_version':{'const':1},'recovery_epoch':{'type':'string'},'seq':{**INT,'minimum':1},'event_id':UUID,'type':{'enum':event_types},'phase_id':nullable(UUID),'occurred_at':DATE,'payload':obj({'replace':obj(models,[])})})})
reply=obj({'command_id':UUID,'status':{'enum':['committed','rejected']},'receipt_seq':INT,'trace_id':UUID,'result':{'type':'object'},'error':{'type':'object'}},['command_id','status','receipt_seq','trace_id'])
reply['oneOf']=[{'properties':{'status':{'const':'committed'}},'required':['result'],'not':{'required':['error']}},{'properties':{'status':{'const':'rejected'}},'required':['error'],'not':{'required':['result']}}]
write('contracts/ws/receipt.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**reply})
result=obj({'narrative':{'type':'string','maxLength':2000},'evidence_ids':{'type':'array','items':CODE,'maxItems':100}})
write('contracts/work/player_hint_complete.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**obj({'attempt':{**INT,'minimum':1},'lease_token':{'type':'string','minLength':1},'result_hash':{'type':'string','pattern':'^[a-f0-9]{64}$'},'result':result})})
g=ROOT/'content/demo/story.json'
# Frozen sample fixture; graph.schema.json defines the extensible C1 white-list.
sample=json.loads(g.read_text())
write('contracts/content/sample.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema','title':'C1 executable sample content',**obj({k:({'type':'string','minLength':1,'maxLength':120} if k=='title' else UUID if k=='story_id' else {'const':v}) for k,v in sample.items()})})
write('contracts/content/graph.schema.json', graph_schema())
valid={'protocol_version':1,'recovery_epoch':'local-C1','command_id':'22222222-2222-4222-8222-222222222222','phase_id':None,'control_generation':1,'type':'select_role','payload':{'role_code':'investigator'}}
write('contracts/fixtures/command.valid.json',valid)
write('contracts/fixtures/command.invalid.json',{**valid,'actor':'forged'})
write('contracts/fixtures/golden.json',[
 {'name':'truth','shared':['C1','C3'],'votes':['publish','publish','leave'],'ending':'E1'},
 {'name':'missed','shared':['C1'],'votes':['wait','wait','leave'],'ending':'E2'},
 {'name':'echo','shared':[],'votes':['leave','leave','wait'],'ending':'E3'},
 {'name':'tie','shared':['C1','C3'],'votes':['leave','wait','publish'],'ending':'E3'},
 {'name':'abstain','shared':[],'votes':[],'ending':'E3'}])

paths={}
def endpoint(path,method,props=None,security=True,summary='',code='200',required=None):
    spec={'summary':summary or path,'responses':{code:{'description':'C1 JSON envelope'},'400':{'description':'Invalid request'},'401':{'description':'Unauthenticated'},'403':{'description':'Not authorized'},'409':{'description':'Business conflict'},'429':{'description':'Rate limited; authentication returns retry_after_ms and Retry-After'}}}
    if security:spec['security']=[{'bearer':[]}]
    if props is not None:spec['requestBody']={'required':True,'content':{'application/json':{'schema':obj(props,required)}}}
    parameters=[{'name':part[1:-1],'in':'path','required':True,'schema':UUID} for part in path.split('/') if part.startswith('{')]
    if '/rooms/{room_id}/' in path and method=='get':parameters += [{'name':'X-Device-ID','in':'header','required':True,'schema':UUID},{'name':'X-Control-Generation','in':'header','required':True,'schema':INT}]
    if parameters:spec['parameters']=parameters
    paths.setdefault(path,{})[method]=spec
endpoint('/health','get',security=False)
endpoint('/v1/auth/guest','post',{'device_id':UUID,'command_id':UUID},False)
endpoint('/v1/auth/recover','post',{'recovery_code':{'type':'string'},'device_id':UUID,'recovery_request_id':UUID},False)
for prefix in ['/v1/auth','/v1/admin/auth']:
 endpoint(prefix+'/refresh','post',{'refresh_token':{'type':'string'},'device_id':UUID,'refresh_request_id':UUID},False)
 endpoint(prefix+'/logout','post',{})
endpoint('/v1/admin/auth/exchange','post',{'login_code':{'type':'string'},'device_id':UUID,'login_request_id':UUID},False)
for p in ['/v1/me','/v1/stories','/v1/stories/{story_id}','/v1/rooms']:endpoint(p,'get',security=p not in ['/v1/stories','/v1/stories/{story_id}'])
endpoint('/v1/me/erase','post',{'command_id':UUID,'confirmation':{'const':'ERASE_ACCOUNT'}},summary='Irreversible authenticated erasure; revokes identity, preserves deidentified joint results and records an independent restore ledger')
diagnostic_variants=[]
for name, field, values in [('screen_view','screen',['entry','discover','lobby','play','ending','account']),('connection_state','state',['online','offline','reconnecting']),('media_summary','reason',['timeout','buffering','user']),('command_attempt','kind',['select_role','ready','start','media_complete','investigate','share_clue','offer_item','accept_offer','reject_offer','cancel_offer','vote','request_hint','chat_send','request_pause','confirm_pause','cancel_pause','resume','leave_room'])]:
 diagnostic_variants.append(obj({'event_id':UUID,'event_name':{'const':name},'schema_version':{'const':1},'occurred_at':{'type':'string','format':'date-time'},'app_version':{'type':'string','pattern':'^[0-9][A-Za-z0-9.+-]{0,31}$'},'session_id':UUID,'properties':obj({field:{'enum':values}})}))
endpoint('/v1/analytics/batches','post',{'batch_id':UUID,'events':{'type':'array','minItems':1,'maxItems':50,'items':{'oneOf':diagnostic_variants}}},summary='Optional bounded diagnostics; at most 64 KiB; accepted_ids and rejected event IDs; not business success metrics')
endpoint('/v1/rooms','post',{'story_id':UUID,'command_id':UUID},code='201')
endpoint('/v1/rooms/join','post',{'invite_code':{'type':'string','pattern':'^[2-9A-HJ-NP-Z]{8}$'},'command_id':UUID})
endpoint('/v1/rooms/{room_id}/chat/reports','post',{'command_id':UUID,'message_id':UUID,'reason':{'enum':['harassment','privacy','spam','other']}},summary='Reports only an authorized retained public message; server retrieves its text')
paths['/v1/rooms/{room_id}/chat/reports']['post']['parameters'] += [{'name':'X-Device-ID','in':'header','required':True,'schema':UUID},{'name':'X-Control-Generation','in':'header','required':True,'schema':INT}]
endpoint('/v1/admin/chat/reports','get',summary='Reviewer-only queue of explicitly reported public messages')
endpoint('/v1/admin/chat/reports/{report_id}','post',{'command_id':UUID,'status':{'enum':['resolved','dismissed']},'remove_message':BOOL},required=['command_id','status'],summary='Reviewer-only auditable disposition; optional removal forces clean snapshots and invalidates historical chat projections')
endpoint('/v1/rooms/{room_id}/socket-ticket','post',{'device_id':UUID,'takeover':BOOL,'command_id':UUID},required=['device_id','takeover'])
endpoint('/v1/rooms/{room_id}/invites','post',{'command_id':UUID})
for suffix in ['snapshot','events','commands/{command_id}','watermark']:endpoint('/v1/rooms/{room_id}/'+suffix,'get')
for suffix in ['events','watermark']:
 spec=paths['/v1/rooms/{room_id}/'+suffix]['get'];spec['parameters'].append({'name':'recovery_epoch','in':'query','required':True,'schema':{'type':'string'}})
 if suffix=='events':
  for name in ['after_seq','through_seq','limit']:spec['parameters'].append({'name':name,'in':'query','required':name=='after_seq','schema':INT})
endpoint('/v1/media/access','post',{'room_id':UUID,'asset_id':UUID,'device_id':UUID,'control_generation':INT},summary='Authorized 120-second signed video/subtitle URLs and same-view summary; development uses original procedural sample clips')
endpoint('/v1/admin/stories','post',{'title':TEXT,'summary':TEXT,'seat_count':{'type':'integer','minimum':2,'maximum':4},'command_id':UUID})
endpoint('/v1/admin/stories/{story_id}/versions','post',{'base_version_id':UUID,'command_id':UUID},required=['command_id'])
endpoint('/v1/admin/versions/{version_id}','get')
endpoint('/v1/admin/versions/{version_id}','put',{'revision':INT,'graph':{'type':'object'}})
for op in ['validate','approve','publish','availability']:
 props={'command_id':UUID}
 if op=='availability':props.update({'availability':{'enum':['available','unlisted','blocked']},'reason':TEXT})
 else:props['revision']=INT
 if op=='approve':props['content_hash']={'type':'string'}
 if op=='publish':props['approved_hash']={'type':'string'}
 endpoint('/v1/admin/versions/{version_id}/'+op,'post',props)
endpoint('/v1/admin/stories','get')
endpoint('/v1/admin/stories/{story_id}/versions','get')
endpoint('/v1/admin/versions/{version_id}/preview','post',{'revision':INT,'command_id':UUID})
endpoint('/v1/admin/previews/step','post',{'preview_token':{'type':'string','maxLength':65536},'actor_role':CODE,'type':CODE,'payload':{'type':'object'},'command_id':UUID,'target_version':INT},required=['preview_token','actor_role','type','payload','command_id'])
endpoint('/v1/admin/jobs/{job_id}','get')
endpoint('/internal/work/claim','post',{'worker_id':TEXT,'supported_kinds':{'const':['player_hint']},'claim_id':UUID})
for op in ['heartbeat','complete','fail']:
 props={'attempt':INT,'lease_token':TEXT}
 if op=='complete':props.update({'result_hash':TEXT,'result':result})
 if op=='fail':props.update({'code':CODE,'retryable':BOOL})
 endpoint('/internal/work/{job_id}/'+op,'post',props)
paths['/internal/work/claim']['post']['responses']['204']={'description':'No available work'}
write('contracts/http/openapi.json',{'openapi':'3.1.0','info':{'title':'入戏 C1 development API','version':'0.1.0','description':'Implemented sample slice. Original media uploads, full content AST, production retention and analytics are tracked in docs/IMPLEMENTATION_STATUS.md.'},'servers':[{'url':'http://localhost:4000'}],'paths':paths,'components':{'securitySchemes':{'bearer':{'type':'http','scheme':'bearer'}}}})
print(f'Generated {len(paths)} HTTP paths and C1 WS/work/content fixtures')
