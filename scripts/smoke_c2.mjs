import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const base=process.env.API_BASE ?? 'http://localhost:4000';
const uuid=()=>crypto.randomUUID();
async function api(method,path,body={},token='',headers={}) {
 const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{ }),...headers},body:method==='GET'?undefined:JSON.stringify(body),signal:AbortSignal.timeout(15000)});
 const value=await r.json();assert(r.ok,`${path}: ${value.error?.code ?? r.status}`);return value.data;
}
const credential=JSON.parse(await readFile(new URL('../.local/admin-review.json',import.meta.url),'utf8'));
const admin=await api('POST','/api/v1/admin/auth/login',{username:credential.username,password:credential.password,device_id:uuid(),login_request_id:uuid()});
const studio=(method,path,body={},rev)=>api(method,'/api/v2'+path,body,admin.access_token,{'Idempotency-Key':uuid(),...(rev?{'If-Match':String(rev)}:{})});
const story=JSON.parse(await readFile(new URL('../content/c2/restaurant.json',import.meta.url),'utf8'));
const project=await studio('POST','/projects',{title:`C2 验收 · ${new Date().toISOString()}`,seat_count:3});
const draft=await studio('PUT',`/projects/${project.id}/draft`,{content:story},1);
await studio('POST',`/projects/${project.id}/reviews`,{content_hash:draft.hash,decision:'approve',reason:'自动化预设路径与三人 Socket 验证'});
const release=await studio('POST',`/projects/${project.id}/releases`,{content_hash:draft.hash});
const players=[];
for(let i=0;i<3;i++)players.push(await api('POST','/api/v1/auth/guest',{device_id:uuid(),command_id:uuid()}));
const room=await api('POST','/api/v2/rooms',{release_id:release.release_id},players[0].access_token,{'Idempotency-Key':uuid()});
const rid=room.room_id;
for(const p of players.slice(1))await api('POST','/api/v2/rooms/join',{invite_code:room.invite_code},p.access_token,{'Idempotency-Key':uuid()});
const snap=i=>api('GET',`/api/v2/rooms/${rid}/snapshot`,{},players[i].access_token);
async function command(i,type,body={},fixed) {
 const s=await snap(i);
 const c=fixed??{protocol_version:2,command_id:uuid(),control_epoch:s.control_epoch,step_id:s.blocks.room.step_id??null,type,body};
 const r=await api('POST',`/api/v2/rooms/${rid}/commands`,c,players[i].access_token);assert.notEqual(r.status,'rejected',`${type}: ${r.code}`);return {c,r};
}
const roles=['guest','doctor','reporter'];
for(let i=0;i<3;i++){await command(i,'role.select',{role_id:roles[i]});await command(i,'member.ready',{ready:true});}
const ticket=await api('POST',`/api/v2/rooms/${rid}/socket-ticket`,{},players[0].access_token);
const ws=new WebSocket(base.replace(/^http/,'ws')+`/api/socket/websocket?vsn=2.0.0&ticket=${encodeURIComponent(ticket.socket_ticket)}`);
const frames=[];
ws.addEventListener('message',e=>frames.push(JSON.parse(e.data)));
await new Promise((resolve,reject)=>{ws.addEventListener('open',resolve,{once:true});ws.addEventListener('error',reject,{once:true});});
const topic=`room:${rid}:member:${ticket.member_id}`;
ws.send(JSON.stringify(['1','1',topic,'phx_join',{protocol_version:2,control_epoch:ticket.control_epoch}]));
async function until(fn){const end=Date.now()+5000;while(Date.now()<end){if(fn())return;await new Promise(r=>setTimeout(r,25));}throw new Error('Socket delivery timeout');}
try {
 await until(()=>frames.some(f=>f[3]==='phx_reply'&&f[4].status==='ok'));
 await command(0,'room.start');
 for(let i=0;i<3;i++){const s=await snap(i);for(const c of s.blocks.narrative_cues)await command(i,'media.complete',{cue_id:c.id,mode:'summary'});}
 let previousRound=0;
 for(const action_id of ['ask','move:dining_hall','unlock','move:hall_kitchen','switch_off']) {
  const s=await snap(0);
  if(previousRound!==s.blocks.room.round){previousRound=s.blocks.room.round;await command(1,'round.end');await command(2,'round.end');}
  const {c,r}=await command(0,'action.submit',{action_id,target_id:null});
  const retry=await command(0,'action.submit',{},c);assert.deepEqual(retry.r,r);
 }
 const end=await snap(0);assert.equal(end.blocks.room.ending.id,'safe');
 const other=await snap(1);assert(!other.blocks.knowledge.some(k=>k.id==='access'));
 await until(()=>frames.some(f=>f[3]==='room.view'&&f[4].blocks.room.ending?.id==='safe'));
 console.log(JSON.stringify({passed:true,protocol_version:2,players:3,ending:'safe',socket_views:frames.filter(f=>f[3]==='room.view').length,project_id:project.id}));
} finally {ws.close();}
