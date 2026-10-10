import {readFile,writeFile,mkdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
import {isDeepStrictEqual} from 'node:util';
const base=process.env.API_BASE ?? 'http://localhost:4000';
const uuid=()=>crypto.randomUUID();
const caps=['password_v1','check_v1','world_projection_v2'];
async function api(method,path,body={},token='',headers={},expected=200) {
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{ }),...headers},body:method==='GET'?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
 const value=await r.json();assert.equal(r.status,expected,`${path}: ${value.error?.code ?? r.status}`);return expected===200?value.data:value;
}
const credential=JSON.parse(await readFile(new URL('../.local/admin-review.json',import.meta.url),'utf8'));
const admin=await api('POST','/api/v1/admin/auth/login',{username:credential.username,password:credential.password,device_id:uuid(),login_request_id:uuid()});
const studio=(method,path,body={},rev)=>api(method,'/api/v2'+path,body,admin.access_token,{'Idempotency-Key':uuid(),...(rev?{'If-Match':String(rev)}:{})});
const story=JSON.parse(await readFile(new URL('../content/c3/rain_archive.json',import.meta.url),'utf8'));
let project=(await studio('GET','/projects')).items.find(p=>p.title===story.title);
if(!project) project=await studio('POST','/projects',{title:story.title,seat_count:3,category:'mystery',summary:'三人雨夜探索。存在秘密目标；密码谜题与服务端骰子判定，修电失败仍可安全撤离。'});
let current=await studio('GET',`/projects/${project.id}/draft`);
if(!isDeepStrictEqual(current.content,story))current=await studio('PUT',`/projects/${project.id}/draft`,{content:story},current.revision);
assert((await studio('POST',`/projects/${project.id}/validate`)).valid);
await studio('POST',`/projects/${project.id}/reviews`,{content_hash:current.hash,decision:'approve',reason:'C3 密码、判定、封返程和私有投影联调夹具'});
const release=await studio('POST',`/projects/${project.id}/releases`,{content_hash:current.hash});
const players=await Promise.all(caps.map(()=>api('POST','/api/v1/auth/guest',{device_id:uuid(),command_id:uuid()})));
const old=await api('POST','/api/v2/rooms',{release_id:release.release_id},players[0].access_token,{'Idempotency-Key':uuid()},400);
assert.equal(old.error.code,'UNSUPPORTED_CAPABILITY');
const room=await api('POST','/api/v2/rooms',{release_id:release.release_id,capabilities:caps},players[0].access_token,{'Idempotency-Key':uuid()});
for(const p of players.slice(1))await api('POST','/api/v2/rooms/join',{invite_code:room.invite_code,capabilities:caps},p.access_token,{'Idempotency-Key':uuid()});
const snap=(p)=>api('GET',`/api/v2/rooms/${room.room_id}/snapshot`,{},p.access_token);
async function command(p,type,body={},saved) {
 const s=await snap(p);
 const c=saved??{protocol_version:3,command_id:uuid(),control_epoch:s.control_epoch,step_id:s.blocks.room.step_id??null,type,body};
 const r=await api('POST',`/api/v2/rooms/${room.room_id}/commands`,c,p.access_token);
 assert.notEqual(r.status,'rejected',`${type}: ${r.error?.code}`);return {c,r};
}
for(const [i,role] of ['investigator','technician','custodian'].entries()) {await command(players[i],'role.select',{role_id:role});await command(players[i],'member.ready',{ready:true});}
await command(players[0],'room.start');
for(const p of players)for(const cue of (await snap(p)).blocks.narrative_cues)await command(p,'media.complete',{cue_id:cue.id,mode:'summary'});
const hidden=await snap(players[0]);assert(!JSON.stringify(hidden.blocks).includes('维修间'));assert(!JSON.stringify(hidden.blocks).includes('safe_code'));
await command(players[0],'action.submit',{action_id:'read_receipt',target_id:null});
await command(players[2],'action.submit',{action_id:'read_receipt',target_id:null});
await command(players[1],'action.submit',{action_id:'move:duty_maintenance_ab',target_id:null});
async function quote(p,id){const s=await snap(p);return api('POST',`/api/v2/rooms/${room.room_id}/interaction-quotes`,{interaction_id:id,step_id:s.blocks.room.step_id},p.access_token);}
const q=await quote(players[1],'repair_power');assert.equal(q.check_preview.target,60);
await command(players[1],'interaction.submit',{quote_id:q.quote_id,kind:'check',input:{}});
await command(players[0],'action.submit',{action_id:'move:duty_archive_ab',target_id:null});
await command(players[2],'action.submit',{action_id:'move:duty_archive_ab',target_id:null});
const tech=await snap(players[1]);const draw=tech.blocks.interaction_results.find(r=>r.kind==='check');assert(draw.roll>=1&&draw.roll<=100);assert.equal(draw.target,60);
assert.equal((await snap(players[1])).blocks.interaction_results[0].roll,draw.roll);
assert(!(await snap(players[0])).blocks.interaction_results.some(r=>r.kind==='check'));
const q1=await quote(players[0],'safe_password');const q2=await quote(players[2],'safe_password');
assert(!JSON.stringify(q1).includes('0427'));
const invalid=await api('POST',`/api/v2/rooms/${room.room_id}/commands`,{protocol_version:3,command_id:uuid(),control_epoch:1,step_id:(await snap(players[0])).blocks.room.step_id,type:'interaction.submit',body:{quote_id:q1.quote_id,kind:'password',input:{answer:'427'}}},players[0].access_token);
assert.equal(invalid.error.code,'INPUT_INVALID');
const wrong=await command(players[2],'interaction.submit',{quote_id:q2.quote_id,kind:'password',input:{answer:'1111'}});
await command(players[0],'interaction.submit',{quote_id:q1.quote_id,kind:'password',input:{answer:'0427'}});
await command(players[1],'round.end');
const before=await snap(players[2]);await command(players[2],'interaction.submit',{},wrong.c);const after=await snap(players[2]);assert.deepEqual(after.blocks.self,before.blocks.self);
const conflict=await api('POST',`/api/v2/rooms/${room.room_id}/commands`,{...wrong.c,body:{...wrong.c.body,input:{answer:'2222'}}},players[2].access_token,{},409);assert.equal(conflict.error.code,'IDEMPOTENCY_CONFLICT');assert(!JSON.stringify(conflict).includes('2222'));
for(const p of players)for(const cue of (await snap(p)).blocks.narrative_cues.filter(c=>!(before.blocks.acknowledged_cues??[]).includes(c.id)))await command(p,'media.complete',{cue_id:cue.id,mode:'summary'});
assert((await snap(players[0])).blocks.interaction_results.some(r=>r.kind==='password'&&r.success));
const preview=await studio('POST',`/projects/${project.id}/projection-preview`,{draft_revision:current.revision,role_id:'investigator',fixture_id:'initial'});assert(!JSON.stringify(preview).includes('维修间'));assert(!JSON.stringify(preview).includes('safe_code'));
// Complete a preset-only route; repair failure does not prevent evacuation.
await command(players[0],'action.submit',{action_id:'take_ledger',target_id:null});
await command(players[1],'action.submit',{action_id:'move:duty_maintenance_ba',target_id:null});
await command(players[2],'round.end');
await command(players[0],'action.submit',{action_id:'copy_ledger',target_id:null});
await command(players[1],'action.submit',{action_id:'read_receipt',target_id:null});
await command(players[0],'action.submit',{action_id:'move:archive_exit_ab',target_id:null});
await command(players[1],'action.submit',{action_id:'move:duty_archive_ab',target_id:null});
// Custodian already discovered the exit in round one; another known-safe route remains.
await command(players[0],'action.submit',{action_id:'submit_copy',target_id:null});
await command(players[2],'action.submit',{action_id:'move:archive_exit_ab',target_id:null});
await command(players[1],'action.submit',{action_id:'move:archive_exit_ab',target_id:null});
for(let round=0;round<6 && (await snap(players[0])).blocks.room.status==='active';round++) {
 for(const p of players) { const v=(await snap(p)).blocks; if(v.room.status==='active'&&!v.self.ended) await command(p,'round.end'); }
}
const ending=(await snap(players[0])).blocks;
assert.equal(ending.room.status,'ending');
assert.equal(ending.room.ending.id,'closing');
assert.equal(ending.self.objectives.find(o=>o.id==='submit').result,'achieved');
assert.equal(ending.self.objectives.find(o=>o.id==='escape').result,'achieved');
assert.equal((await snap(players[2])).blocks.self.objectives.find(o=>o.id==='cover').result,'failed');
for(const p of players)assert.equal((await snap(p)).blocks.self.objectives.find(o=>o.id==='escape').result,'achieved');
const evidence={passed:true,story_id:project.id,room_id:room.room_id,content_hash:current.hash,protocol_version:3,checks:['capability-gate','private-map','quote-no-answer','format-free','server-check','private-roll','retry-once','answer-conflict','leading-zero','role-preview','preset-ending','private-objective-results'],player_url:`http://localhost:8080/stories/${project.id}`};
await mkdir(new URL('../.local/c3/',import.meta.url),{recursive:true});await writeFile(new URL('../.local/c3/http-evidence.json',import.meta.url),JSON.stringify(evidence,null,2));console.log(JSON.stringify(evidence));
