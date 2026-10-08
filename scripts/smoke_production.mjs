import assert from 'node:assert/strict';
import {randomUUID, createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
const base=process.env.API_BASE??'http://localhost:4000';
const core=new URL('../services/core/',import.meta.url);
const output=execFileSync('mix',['run','--no-start','priv/repo/admin_code.exs',randomUUID(),'editor','reviewer','publisher'],{cwd:core,encoding:'utf8',env:{...process.env,PHX_SERVER:'false'}});
const code=output.match(/minutes\):\s*(\S+)/)?.[1]; assert.ok(code);
let token='';
async function api(method,path,body){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},...(body?{body:JSON.stringify(body)}:{})});const d=await r.json();assert.ok(r.ok,JSON.stringify(d.error));return d.data;}
token=(await api('POST','/v1/admin/auth/exchange',{login_code:code,device_id:randomUUID(),login_request_id:randomUUID()})).access_token;
const bytes=readFileSync(new URL('../content/demo/media/opening.mp4',import.meta.url));
const sha=createHash('sha256').update(bytes).digest('hex');
const request={command_id:randomUUID(),filename:'synthetic-original-opening.mp4',mime_type:'video/mp4',size_bytes:bytes.length,sha256:sha};
const intent=await api('POST','/v1/admin/assets/upload-intents',request);
assert.deepEqual(await api('POST','/v1/admin/assets/upload-intents',request),intent);
const uploaded=await fetch(intent.upload_url,{method:'PUT',headers:intent.headers,body:bytes});assert.equal(uploaded.status,200);
await api('POST',`/v1/admin/assets/${intent.asset_id}/complete`,{command_id:randomUUID(),sha256:sha,size_bytes:bytes.length,rights_source:'Original procedural graphics authored for Ruxi, MIT portfolio fixture.'});
let asset;
for(let i=0;i<90;i++){asset=(await api('GET','/v1/admin/assets')).items.find(a=>a.asset_id===intent.asset_id);if(['ready','quarantined'].includes(asset.status))break;await new Promise(r=>setTimeout(r,1000));}
assert.equal(asset.status,'ready',asset.error_code);assert.equal(asset.duration_ms,50000);assert.deepEqual(Object.keys(asset.outputs).sort(),['poster','subtitle','video']);
const story=(await api('POST','/v1/admin/stories',{title:'原创素材链路验收',summary:'合成内容，仅用于制作与发布验收。',seat_count:3,command_id:randomUUID()})).story_id;
const draft=await api('POST',`/v1/admin/stories/${story}/versions`,{base_version_id:'11111111-1111-4111-8111-333333333333',command_id:randomUUID()});
const version=await api('GET',`/v1/admin/versions/${draft.version_id}`);
const poster=await api('GET',`/v1/admin/assets/${asset.asset_id}/preview`);
const posterResponse=await fetch(poster.poster_url);assert.equal(posterResponse.status,200);assert.ok(posterResponse.headers.get('content-type').startsWith('image/jpeg'));
const captioned=await api('POST',`/v1/admin/assets/${asset.asset_id}/captions`,{command_id:randomUUID(),vtt:'WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n原创字幕验收。\n'});
version.graph.assets[0]={...version.graph.assets[0],asset_id:captioned.asset_id,sha256:asset.outputs.video.sha256,duration_ms:asset.duration_ms,source:asset.rights_source};
await api('PUT',`/v1/admin/versions/${draft.version_id}`,{revision:1,graph:version.graph});
const ai=await api('POST',`/v1/admin/versions/${draft.version_id}/ai`,{command_id:randomUUID(),revision:2,target:'title',instruction:'保留悬疑氛围，将剧目名称润色为简洁的中文标题。'});
let job;
for(let i=0;i<45;i++){job=await api('GET',`/v1/admin/ai/jobs/${ai.job_id}`);if(['completed','failed'].includes(job.status))break;await new Promise(r=>setTimeout(r,1000));}
assert.equal(job.status,'completed');assert.equal(job.outcome.status,'accepted');assert.equal((await api('GET',`/v1/admin/versions/${draft.version_id}`)).revision,2);
await api('POST',`/v1/admin/ai/jobs/${ai.job_id}/apply`,{command_id:randomUUID(),revision:2});
const current=await api('GET',`/v1/admin/versions/${draft.version_id}`);assert.equal(current.revision,3);assert.equal(current.graph.title,job.proposal.suggested);
const validation=await api('POST',`/v1/admin/versions/${draft.version_id}/validate`,{revision:3,command_id:randomUUID()});
const report=await api('GET',`/v1/admin/jobs/${validation.job_id}`);assert.equal(report.valid,true);assert.equal(report.assets_ready,true);
const approval=await api('POST',`/v1/admin/versions/${draft.version_id}/approve`,{revision:3,content_hash:current.hash,command_id:randomUUID()});
await api('POST',`/v1/admin/versions/${draft.version_id}/publish`,{revision:3,approved_hash:approval.approved_hash,command_id:randomUUID()});
const{Player}=await import('./protocol_client.mjs');const players=[];
try {
 for(let i=0;i<3;i++){const p=new Player();await p.guest();players.push(p);}
 const made=await players[0].http('POST','/v1/rooms',{story_id:story,command_id:randomUUID()});
 for(const p of players.slice(1))await p.http('POST','/v1/rooms/join',{invite_code:made.invite_code,command_id:randomUUID()});
 for(const[i,p]of players.entries()){await p.connect(made.room_id);await p.command('select_role',{role_code:['investigator','passenger','conductor'][i]});await p.command('ready',{ready:true});}
 await players[0].command('start');
 const p=players[0];const access=await p.http('POST','/v1/media/access',{room_id:p.room,asset_id:captioned.asset_id,device_id:p.device,control_generation:p.generation});
 assert.equal((await fetch(access.url,{headers:{Range:'bytes=0-1023'}})).status,206);
 assert.ok((await (await fetch(access.subtitle.url)).text()).includes('原创字幕验收。'));
 await api('POST',`/v1/admin/versions/${draft.version_id}/availability`,{availability:'unlisted',reason:'合成验收完成，不显示在发现页。',command_id:randomUUID()});
}finally{for(const p of players)await p.close();}
await api('POST','/v1/admin/auth/logout',{});
console.log('PASS: real signed immutable upload, Worker decode/transcode/first-frame, output verification, immutable subtitle revision, first-frame preview, frozen publication and authorized playback, inert AI proposal and explicit revision-bound apply. AI source: '+job.proposal.source);
