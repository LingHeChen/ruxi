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
 'public_scene':response({'title':{'type':'string'},'description':{'type':'string'},'shared_clues':arr(clue),'timeline':arr(response({'seq':{**INT,'minimum':1},'kind':{'enum':['phase','lifecycle','shared_clue']},'label':{'type':'string','maxLength':500},'occurred_at':DATE}),200)},['title','description','shared_clues']),
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
endpoint('/api/health','get',security=False)
endpoint('/api/v1/auth/guest','post',{'device_id':UUID,'command_id':UUID},False)
ACCOUNT={'type':'string','minLength':3,'maxLength':64,'pattern':'^[a-zA-Z0-9][a-zA-Z0-9_.@-]{2,63}$'}
PASSWORD={'type':'string','minLength':1,'maxLength':128,'description':'10–128 UTF-8 bytes; never returned or logged'}
endpoint('/api/v1/auth/register','post',{'username':ACCOUNT,'password':PASSWORD,'display_name':{'type':'string','minLength':1,'maxLength':24},'device_id':UUID,'command_id':UUID},False)
for prefix in ['/api/v1/auth','/api/v1/admin/auth']:
 endpoint(prefix+'/login','post',{'username':ACCOUNT,'password':PASSWORD,'device_id':UUID,'login_request_id':UUID},False)
endpoint('/api/v1/auth/password-reset','post',{'recovery_code':{'type':'string','minLength':20,'maxLength':128},'new_password':PASSWORD,'device_id':UUID,'recovery_request_id':UUID},False)
endpoint('/api/v1/me','put',{'display_name':{'type':'string','minLength':1,'maxLength':24},'bio':{'type':'string','maxLength':160},'command_id':UUID})
endpoint('/api/v1/me/password','post',{'current_password':PASSWORD,'new_password':PASSWORD,'command_id':UUID})
endpoint('/api/v1/me/favorites','get')
endpoint('/api/v1/stories/{story_id}/favorite','post',{'saved':BOOL,'command_id':UUID})
endpoint('/api/v1/admin/me','get')
endpoint('/api/v1/admin/users','get')
endpoint('/api/v1/admin/users/{user_id}/roles','post',{'roles':{'type':'array','maxItems':3,'uniqueItems':True,'items':{'enum':['editor','reviewer','publisher']}},'command_id':UUID})
endpoint('/api/v1/admin/stories/{story_id}/metadata','put',{'category':{'enum':['mystery','emotion','scifi','adventure']},'difficulty':{'enum':['beginner','intermediate','advanced']},'summary':{'type':'string','maxLength':1000},'command_id':UUID})
endpoint('/api/v1/auth/recover','post',{'recovery_code':{'type':'string'},'device_id':UUID,'recovery_request_id':UUID},False)
for prefix in ['/api/v1/auth','/api/v1/admin/auth']:
 endpoint(prefix+'/refresh','post',{'refresh_token':{'type':'string'},'device_id':UUID,'refresh_request_id':UUID},False)
 endpoint(prefix+'/logout','post',{})
endpoint('/api/v1/admin/auth/exchange','post',{'login_code':{'type':'string'},'device_id':UUID,'login_request_id':UUID},False)
for p in ['/api/v1/me','/api/v1/stories','/api/v1/stories/{story_id}','/api/v1/rooms']:endpoint(p,'get',security=p not in ['/api/v1/stories','/api/v1/stories/{story_id}'])
endpoint('/api/v1/me/erase','post',{'command_id':UUID,'confirmation':{'const':'ERASE_ACCOUNT'}},summary='Irreversible authenticated erasure; revokes identity, preserves deidentified joint results and records an independent restore ledger')
diagnostic_variants=[]
for name, field, values in [('screen_view','screen',['entry','discover','lobby','play','ending','account']),('connection_state','state',['online','offline','reconnecting']),('media_summary','reason',['timeout','buffering','user']),('command_attempt','kind',['select_role','ready','start','media_complete','investigate','share_clue','offer_item','accept_offer','reject_offer','cancel_offer','vote','request_hint','chat_send','request_pause','confirm_pause','cancel_pause','resume','leave_room'])]:
 diagnostic_variants.append(obj({'event_id':UUID,'event_name':{'const':name},'schema_version':{'const':1},'occurred_at':{'type':'string','format':'date-time'},'app_version':{'type':'string','pattern':'^[0-9][A-Za-z0-9.+-]{0,31}$'},'session_id':UUID,'properties':obj({field:{'enum':values}})}))
endpoint('/api/v1/analytics/batches','post',{'batch_id':UUID,'events':{'type':'array','minItems':1,'maxItems':50,'items':{'oneOf':diagnostic_variants}}},summary='Optional bounded diagnostics; at most 64 KiB; accepted_ids and rejected event IDs; not business success metrics')
paths['/api/v1/stories']['get']['parameters']=[{'name':key,'in':'query','required':False,'schema':schema} for key,schema in {'q':{'type':'string','maxLength':80},'category':{'enum':['mystery','emotion','scifi','adventure']},'seats':{'enum':['2','3','4']},'sort':{'enum':['latest','title']},'offset':{'type':'string','pattern':'^[0-9]{1,5}$'}}.items()]
endpoint('/api/v1/rooms','post',{'story_id':UUID,'command_id':UUID},code='201')
endpoint('/api/v1/rooms/join','post',{'invite_code':{'type':'string','pattern':'^[2-9A-HJ-NP-Z]{8}$'},'command_id':UUID})
endpoint('/api/v1/rooms/{room_id}/chat/reports','post',{'command_id':UUID,'message_id':UUID,'reason':{'enum':['harassment','privacy','spam','other']}},summary='Reports only an authorized retained public message; server retrieves its text')
paths['/api/v1/rooms/{room_id}/chat/reports']['post']['parameters'] += [{'name':'X-Device-ID','in':'header','required':True,'schema':UUID},{'name':'X-Control-Generation','in':'header','required':True,'schema':INT}]
endpoint('/api/v1/admin/chat/reports','get',summary='Reviewer-only queue of explicitly reported public messages')
endpoint('/api/v1/admin/chat/reports/{report_id}','post',{'command_id':UUID,'status':{'enum':['resolved','dismissed']},'remove_message':BOOL},required=['command_id','status'],summary='Reviewer-only auditable disposition; optional removal forces clean snapshots and invalidates historical chat projections')
endpoint('/api/v1/rooms/{room_id}/socket-ticket','post',{'device_id':UUID,'takeover':BOOL,'command_id':UUID},required=['device_id','takeover'])
endpoint('/api/v1/rooms/{room_id}/invites','post',{'command_id':UUID})
for suffix in ['snapshot','events','commands/{command_id}','watermark']:endpoint('/api/v1/rooms/{room_id}/'+suffix,'get')
for suffix in ['events','watermark']:
 spec=paths['/api/v1/rooms/{room_id}/'+suffix]['get'];spec['parameters'].append({'name':'recovery_epoch','in':'query','required':True,'schema':{'type':'string'}})
 if suffix=='events':
  for name in ['after_seq','through_seq','limit']:spec['parameters'].append({'name':name,'in':'query','required':name=='after_seq','schema':INT})
endpoint('/api/v1/media/access','post',{'room_id':UUID,'asset_id':UUID,'device_id':UUID,'control_generation':INT},summary='Authorized 120-second signed video/subtitle URLs and same-view summary; development uses original procedural sample clips')
endpoint('/api/v1/admin/stories','post',{'title':TEXT,'summary':TEXT,'seat_count':{'type':'integer','minimum':2,'maximum':4},'command_id':UUID})
endpoint('/api/v1/admin/stories/{story_id}/versions','post',{'base_version_id':UUID,'command_id':UUID},required=['command_id'])
endpoint('/api/v1/admin/versions/{version_id}','get')
endpoint('/api/v1/admin/versions/{version_id}','put',{'revision':INT,'graph':{'type':'object'}})
for op in ['validate','approve','publish','availability']:
 props={'command_id':UUID}
 if op=='availability':props.update({'availability':{'enum':['available','unlisted','blocked']},'reason':TEXT})
 else:props['revision']=INT
 if op=='approve':props['content_hash']={'type':'string'}
 if op=='publish':props['approved_hash']={'type':'string'}
 endpoint('/api/v1/admin/versions/{version_id}/'+op,'post',props)
endpoint('/api/v1/admin/stories','get')
endpoint('/api/v1/admin/stories/{story_id}/versions','get')
endpoint('/api/v1/admin/versions/{version_id}/preview','post',{'revision':INT,'command_id':UUID})
endpoint('/api/v1/admin/previews/step','post',{'preview_token':{'type':'string','maxLength':65536},'actor_role':CODE,'type':CODE,'payload':{'type':'object'},'command_id':UUID,'target_version':INT},required=['preview_token','actor_role','type','payload','command_id'])
endpoint('/api/v1/admin/jobs/{job_id}','get')
endpoint('/api/internal/work/claim','post',{'worker_id':TEXT,'supported_kinds':{'type':'array','minItems':1,'maxItems':3,'uniqueItems':True,'items':{'enum':['player_hint','media_transcode','editor_ai']}},'claim_id':UUID})
for op in ['heartbeat','complete','fail']:
 props={'attempt':INT,'lease_token':TEXT}
 if op=='complete':props.update({'result_hash':TEXT,'result':{'oneOf':[result,obj({'outputs':arr(obj({'asset_id':UUID,'object_key':TEXT,'sha256':TEXT,'mime_type':TEXT,'size_bytes':INT}),3)}),obj({'proposal_ref':TEXT,'sha256':TEXT})]}})
 if op=='fail':props.update({'code':CODE,'retryable':BOOL})
 endpoint('/api/internal/work/{job_id}/'+op,'post',props)
SHA={'type':'string','pattern':'^[0-9a-f]{64}$'}
endpoint('/api/v1/admin/operations','get',summary='Reviewer-only deidentified committed room outcomes and operational gauges')
endpoint('/api/v1/admin/assets/{asset_id}/captions','post',{'command_id':UUID,'vtt':{'type':'string','maxLength':60000}},summary='Validate plain timed VTT and create a new immutable asset; published subtitle bytes remain frozen')
endpoint('/api/v1/admin/assets/{asset_id}/preview','get',summary='Editor-owned 60-second first-frame preview, revoked with the session')
endpoint('/api/v1/admin/assets','get',summary='Editor-owned production assets and transcode state')
endpoint('/api/v1/admin/assets/upload-intents','post',{'command_id':UUID,'filename':{'type':'string','minLength':1,'maxLength':180},'mime_type':{'enum':['video/mp4','video/webm','video/quicktime']},'size_bytes':{'type':'integer','minimum':1,'maximum':524288000},'sha256':SHA})
endpoint('/api/v1/admin/assets/{asset_id}/complete','post',{'command_id':UUID,'sha256':SHA,'size_bytes':INT,'rights_source':{'type':'string','minLength':1,'maxLength':2000}})
endpoint('/api/v1/admin/versions/{version_id}/ai','post',{'command_id':UUID,'revision':INT,'target':{'enum':['title','description','asset_summary']},'instruction':TEXT,'media_id':CODE},required=['command_id','revision','target','instruction'])
endpoint('/api/v1/admin/ai/jobs/{job_id}','get')
endpoint('/api/v1/admin/ai/jobs/{job_id}/apply','post',{'command_id':UUID,'revision':INT},summary='Explicit human acceptance bound to the frozen proposal revision and hash')
endpoint('/api/internal/work/{job_id}/output-intents','post',{'attempt':INT,'lease_token':TEXT,'outputs':arr(obj({'kind':{'enum':['video','poster','subtitle','proposal']},'size_bytes':INT,'sha256':SHA}),3)})
endpoint('/api/internal/work/{job_id}/source','get',summary='Worker-only source stream; X-Work-Attempt and X-Lease-Token required')
paths['/api/internal/work/{job_id}/source']['get']['parameters'] += [{'name':'X-Work-Attempt','in':'header','required':True,'schema':INT},{'name':'X-Lease-Token','in':'header','required':True,'schema':TEXT}]
paths['/api/internal/work/claim']['post']['responses']['204']={'description':'No available work'}
write('contracts/http/openapi.json',{'openapi':'3.1.0','info':{'title':'入戏 C1 development API','version':'0.1.0','description':'Authoritative multiplayer game, creator content pipeline, bounded AI and media processing. Operational validation is tracked in docs/IMPLEMENTATION_STATUS.md.'},'servers':[{'url':'http://localhost:4000'}],'paths':paths,'components':{'securitySchemes':{'bearer':{'type':'http','scheme':'bearer'}}}})
proposal=obj({'schema_version':{'const':1},'target':{'oneOf':[{'const':['title']},{'const':['description']}, {'type':'array','prefixItems':[{'const':'assets'},INT,{'const':'summary'}],'minItems':3,'maxItems':3}]},'original':{'type':'string','maxLength':2000},'suggested':{'type':'string','minLength':1,'maxLength':2000},'notes':arr({'type':'string','maxLength':200},5),'source':{'enum':['ai','template']}})
write('contracts/work/editor_proposal.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**proposal})
write('contracts/work/editor_ai_complete.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**obj({'attempt':INT,'lease_token':TEXT,'result_hash':SHA,'result':obj({'proposal_ref':TEXT,'sha256':SHA})})})
write('contracts/work/media_transcode_complete.schema.json',{'$schema':'https://json-schema.org/draft/2020-12/schema',**obj({'attempt':INT,'lease_token':TEXT,'result_hash':SHA,'result':obj({'outputs':{'type':'array','minItems':3,'maxItems':3,'items':obj({'asset_id':UUID,'object_key':TEXT,'sha256':SHA,'mime_type':{'enum':['video/mp4','image/jpeg','text/vtt']},'size_bytes':{'type':'integer','minimum':1,'maximum':524288000}})}})})})
print(f'Generated {len(paths)} HTTP paths and C1 WS/work/content fixtures')
