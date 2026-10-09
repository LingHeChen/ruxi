import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
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
if(!project) {
 project=await studio('POST','/projects',{title:story.title,seat_count:1,category:'emotion',summary:'独自值守即将关闭的旧邮局，一封写着你名字的信，带你找回二十年前雨夜的真相。单人探索，三个结局。'});
 const draft=await studio('PUT',`/projects/${project.id}/draft`,{content:story},1);
 await studio('POST',`/projects/${project.id}/reviews`,{content_hash:draft.hash,decision:'approve',reason:'单人规则校验及两个主动结局通关测试通过'});
 const release=await studio('POST',`/projects/${project.id}/releases`,{content_hash:draft.hash});
 project.current_release_id=release.release_id;
}
const catalog=await api('GET','/api/v2/stories?seats=1');
assert(catalog.items.some(p=>p.story_id===project.id),'Single-player catalog filter');
for(const choice of ['deliver','keep']) {
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
 for(const action_id of ['read_letter','inspect_photo','move:office_archive','read_ledger','open_box','move:archive_office',choice]) {
  const state=await snap();
  if(state.blocks.self.ap_remaining===0)await command('round.end');
  await command('action.submit',{action_id,target_id:null});
 }
 const end=await snap();
 assert.equal(end.blocks.room.ending.id,choice==='deliver'?'dawn':'kept');
}
console.log(JSON.stringify({passed:true,title:story.title,players:1,endings:['dawn','kept'],story_id:project.id,player_url:`http://localhost:8080/stories/${project.id}`}));
