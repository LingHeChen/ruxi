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
const admin=await api('POST','/v1/admin/auth/login',{username:credential.username,password:credential.password,device_id:uuid(),login_request_id:uuid()});
const studio=(method,path,body={},rev)=>api(method,'/api/v2'+path,body,admin.access_token,{'Idempotency-Key':uuid(),...(rev?{'If-Match':String(rev)}:{})});
const story=JSON.parse(await readFile(new URL('../content/c3/tide_hotel/story.json',import.meta.url),'utf8'));
let project=(await studio('GET','/projects')).items.find(p=>p.title===story.title);
if(!project)project=await studio('POST','/projects',{title:story.title,seat_count:1,category:'mystery',summary:'单人悬疑｜预计30～60分钟。暴雨封岛，作家江临在第九声钟响后失踪。八个场景、四名可回访NPC、证词互证、密码与判定、五种结局。'});
let draft=await studio('GET',`/projects/${project.id}/draft`);
if(!isDeepStrictEqual(draft.content,story))draft=await studio('PUT',`/projects/${project.id}/draft`,{content:story},draft.revision);
assert((await studio('POST',`/projects/${project.id}/validate`)).valid);
await studio('POST',`/projects/${project.id}/reviews`,{content_hash:draft.hash,decision:'approve',reason:'单人NPC悬疑脚本，五结局及概率失败替代路线经过引擎验证'});
const release=await studio('POST',`/projects/${project.id}/releases`,{content_hash:draft.hash});
const catalog=await api('GET',`/api/v2/stories/${project.id}`);
assert.deepEqual(catalog.playtime_minutes,{min:30,max:60});assert(catalog.cover_uri.endsWith('/cover.png'));
const cases=[['publish_truth','shore_names','pin'],['seal_handover','seven_days','bypass'],['accuse_murder','loud_error','exhaust'],['leave_early','unanswered','early'],['rounds','storm_passed','rounds']];
const evidence=[];
for(const [choice,ending,mode] of cases){
 const p=await api('POST','/v1/auth/guest',{device_id:uuid(),command_id:uuid()});
 const room=await api('POST','/api/v2/rooms',{release_id:release.release_id,capabilities:caps},p.access_token,{'Idempotency-Key':uuid()});
 const snap=()=>api('GET',`/api/v2/rooms/${room.room_id}/snapshot`,{},p.access_token);
 async function command(type,body={}){const v=await snap();const r=await api('POST',`/api/v2/rooms/${room.room_id}/commands`,{protocol_version:3,command_id:uuid(),control_epoch:v.control_epoch,step_id:v.blocks.room.step_id??null,type,body},p.access_token);assert.notEqual(r.status,'rejected',`${type}/${body.action_id}: ${r.error?.code}`);}
 // Re-read acknowledgements after every command so round-transition cues remain resumable.
 async function read(){let v=(await snap()).blocks;for(const c of v.narrative_cues.filter(c=>!v.acknowledged_cues.includes(c.id)))await command('media.complete',{cue_id:c.id,mode:'summary'});}
 async function act(id){let v=(await snap()).blocks;const a=v.actions.find(a=>a.id===id);const cost=a?.cost??1;if(v.self.ap_remaining<cost){await command('round.end');await read();}await command('action.submit',{action_id:id,target_id:null});await read();}
 async function go(dest){let count=0;while((await snap()).blocks.self.location!==dest){assert(count++<10,'map path loop');const v=(await snap()).blocks;const adj={};for(const l of story.c3.passages){for(const dir of ['ab','ba'])if(l[dir]){if(l[dir].enter_if.op==='known'&&!v.knowledge.some(k=>k.id===l[dir].enter_if.ref))continue;const from=dir==='ab'?l.a:l.b,to=dir==='ab'?l.b:l.a;(adj[from]??=[]).push({to,id:`${l.id}_${dir}`});}}
  const queue=[[v.self.location,[]]],seen=new Set();let path;while(queue.length){const [at,steps]=queue.shift();if(at===dest){path=steps;break;}if(seen.has(at))continue;seen.add(at);for(const l of adj[at]??[])queue.push([l.to,[...steps,l.id]]);}assert(path?.length,`no route ${dest}`);await act('move:'+path[0]);}}
 async function route(loc,ids){await go(loc);for(const id of ids)await act(id);}
 await command('role.select',{role_id:'reporter'});await command('member.ready',{ready:true});await command('room.start');await read();
 const initial=(await snap()).blocks;assert.deepEqual(initial.npcs.map(n=>n.id),['lin']);assert(!JSON.stringify(initial).includes('cabinet_code'));
 if(mode==='early')await act('leave_early');
 else if(mode==='rounds'){for(let i=0;i<24;i++){await command('round.end');await read();}}
 else{
  await route('lobby',['read_receipt','talk_lin','ask_lin_family']);
  await route('lounge',['inspect_clock','listen_window']);await route('corridor',['inspect_tracks']);await route('room209',['inspect_luggage','play_tape']);
  await route('infirmary',['talk_chen','inspect_medicine','ask_chen_oldcase','ask_chen_call']);await route('generator',['talk_zhao','inspect_wire','manual_log','tell_zhao_medical']);
  await route('archive',['read_register']);
  if(mode==='pin'||mode==='exhaust')for(let i=0;i<(mode==='pin'?1:6);i++){
   let v=(await snap()).blocks;if(v.self.ap_remaining===0){await command('round.end');await read();v=(await snap()).blocks;}
   const q=await api('POST',`/api/v2/rooms/${room.room_id}/interaction-quotes`,{interaction_id:'cabinet_password',step_id:v.room.step_id},p.access_token);
   await command('interaction.submit',{quote_id:q.quote_id,kind:'password',input:{answer:mode==='pin'?'0921':'0000'}});await read();}
  if(mode!=='pin')await act('bypass_cabinet');
  await route('archive',['read_rescue','read_unsent_letter','copy_evidence']);await route('boathouse',['talk_he','inspect_rope','ask_he_departure','ask_he_rescue','call_station']);
  await route('lobby',['confront_lin']);await route('lounge',['reconstruct',choice]);
 }
 const final=(await snap()).blocks;assert.equal(final.room.ending.id,ending);assert(final.room.ending.uri.endsWith('.png'));
 if(!['early','rounds'].includes(mode)){assert(final.action_history.length>30);assert.equal(final.self.objectives.find(o=>o.id==='find_jiang').result,'achieved');assert(final.knowledge.every(k=>k.image_uri));}
 evidence.push({room_id:room.room_id,mode,ending,round:final.room.round,actions:final.action_history.length});
}
const result={passed:true,story_id:project.id,content_hash:draft.hash,player_url:`http://localhost:8080/stories/${project.id}`,routes:evidence};
await mkdir(new URL('../.local/tide_hotel/',import.meta.url),{recursive:true});await writeFile(new URL('../.local/tide_hotel/http-evidence.json',import.meta.url),JSON.stringify(result,null,2));console.log(JSON.stringify(result));
