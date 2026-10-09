import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {isDeepStrictEqual} from 'node:util';
const base=process.env.API_BASE ?? 'http://localhost:4000';
const uuid=()=>crypto.randomUUID();
async function api(method,path,body={},token='',headers={}) {
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{ }),...headers},body:method==='GET'?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
 const value=await r.json();assert(r.ok,`${path}: ${value.error?.code ?? r.status}`);return value.data;
}
const credential=JSON.parse(await readFile(new URL('../.local/admin-review.json',import.meta.url),'utf8'));
const admin=await api('POST','/v1/admin/auth/login',{username:credential.username,password:credential.password,device_id:uuid(),login_request_id:uuid()});
const studio=(method,path,body={},rev)=>api(method,'/api/v2'+path,body,admin.access_token,{'Idempotency-Key':uuid(),...(rev?{'If-Match':String(rev)}:{})});

const story=JSON.parse(await readFile(new URL('../content/c2/last_letter.json',import.meta.url),'utf8'));
const existing=await studio('GET','/projects');
let project=existing.items.find(p=>p.title===story.title);
if(!project) project=await studio('POST','/projects',{title:story.title,seat_count:1,category:'emotion',summary:'独自值守即将关闭的旧邮局，一封写着你名字的信，带你找回二十年前雨夜的真相。单人探索，三个结局。'});
const current=await studio('GET',`/projects/${project.id}/draft`);
if(!isDeepStrictEqual(current.content,story)) {
 const draft=await studio('PUT',`/projects/${project.id}/draft`,{content:story},current.revision);
 await studio('POST',`/projects/${project.id}/reviews`,{content_hash:draft.hash,decision:'approve',reason:'单人规则校验及两个主动结局通关测试通过'});
 const release=await studio('POST',`/projects/${project.id}/releases`,{content_hash:draft.hash});
 project.current_release_id=release.release_id;
}
const catalog=await api('GET','/api/v2/stories?seats=1');
assert(catalog.items.some(p=>p.story_id===project.id),'Single-player catalog filter');
const endings=new Set();
for(const saved of ['ledger','tape']) for(const memory of [false,true]) for(const choice of ['deliver','keep']) {
 const player=await api('POST','/v1/auth/guest',{device_id:uuid(),command_id:uuid()});
 const room=await api('POST','/api/v2/rooms',{release_id:project.current_release_id},player.access_token,{'Idempotency-Key':uuid()});
 const snap=()=>api('GET',`/api/v2/rooms/${room.room_id}/snapshot`,{},player.access_token);
 async function command(type,body={}) {
  const s=await snap();
  const r=await api('POST',`/api/v2/rooms/${room.room_id}/commands`,{protocol_version:2,command_id:uuid(),control_epoch:s.control_epoch,step_id:s.blocks.room.step_id??null,type,body},player.access_token);
  assert.notEqual(r.status,'rejected',`${type}: ${r.code}`);
 }
 await command('role.select',{role_id:'keeper'});
 await command('member.ready',{ready:true});
 await command('room.start');
 for(const cue of (await snap()).blocks.narrative_cues)await command('media.complete',{cue_id:cue.id,mode:'summary'});
 for(const action_id of ['read_letter','inspect_postmark',...(memory?['inspect_photo']:[]),'move:office_archive','inspect_damage',`rescue_${saved}`,'open_box','deduce_rescue','move:archive_office',choice]) {
  const state=await snap();
  if(state.blocks.self.ap_remaining<(action_id.startsWith('rescue_')?2:1)) { await command('round.end'); const pass=await snap(); for(const cue of pass.blocks.narrative_cues.filter(c=>!pass.blocks.acknowledged_cues.includes(c.id))) await command('media.complete',{cue_id:cue.id,mode:'summary'}); }
  await command('action.submit',{action_id,target_id:null});
  const updated=await snap();
  for(const cue of updated.blocks.narrative_cues.filter(c=>!updated.blocks.acknowledged_cues.includes(c.id))) await command('media.complete',{cue_id:cue.id,mode:'summary'});
 }
 const end=await snap();
 const expected=choice==='keep'?(memory?'kept_memory':'kept'):(saved==='tape'&&!memory?'dawn':`dawn_${saved}${memory?'_memory':''}`);
 assert.equal(end.blocks.room.ending.id,expected);
 assert(end.blocks.inventory.some(i=>i.id===saved));
 assert(!end.blocks.inventory.some(i=>i.id===(saved==='ledger'?'tape':'ledger')));
 assert(end.blocks.action_history.length>=9);
 endings.add(expected);
}
console.log(JSON.stringify({passed:true,title:story.title,players:1,endings:[...endings],routes:8,story_id:project.id,player_url:`http://localhost:8080/stories/${project.id}`}));
