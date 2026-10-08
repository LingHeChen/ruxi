import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
const base=process.env.API_BASE ?? 'http://localhost:4000';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function eventually(fn,timeout=10000){const end=Date.now()+timeout;while(Date.now()<end){if(await fn())return;await sleep(30);}throw Error('condition timed out');}
class Player{
 constructor(){this.device=randomUUID();this.ref=0;this.pending=new Map();this.view=null;this.seq=0;this.events=[];this.frames=[];this.synced=false;}
 async http(method,path,body,privateRead=false){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(this.token?{'Authorization':'Bearer '+this.token}:{}),...(privateRead?{'X-Device-ID':this.device,'X-Control-Generation':String(this.generation)}:{})},...(method==='GET'?{}:{body:JSON.stringify(body)})});const v=await r.json();if(r.status>=400)throw Object.assign(Error(v.error.code),{code:v.error.code});return v.data;}
 async guest(){const a=await this.http('POST','/v1/auth/guest',{device_id:this.device,command_id:randomUUID()});this.token=a.access_token;this.user=a.user_id;}
 async connect(room,replay=false){const cachedSeq=replay?this.seq:0;const cachedEpoch=this.epoch;this.synced=false;this.room=room;const t=await this.http('POST',`/v1/rooms/${room}/socket-ticket`,{device_id:this.device,takeover:false});this.member=t.membership_id;this.generation=t.control_generation;this.epoch=t.recovery_epoch;this.topic=`player_room:${room}:${this.member}`;this.ws=new WebSocket(base.replace(/^http/,'ws')+`/socket/websocket?vsn=2.0.0&ticket=${t.socket_ticket}`);this.join='j'+(++this.ref);
  this.ws.onmessage=({data})=>{const f=JSON.parse(data);this.frames.push(f);const [_,ref,topic,event,p]=f;if(event==='phx_reply'){const c=this.pending.get(ref);if(c){this.pending.delete(ref);c(p);}}else if(event==='sync_snapshot'){this.view=p.snapshot;this.seq=p.base_seq;this.epoch=p.recovery_epoch;}else if(event==='view_event'){this.events.push(p);if(p.seq>this.seq){assert.equal(p.seq,this.seq+1);this.view={...this.view,...p.payload.replace};this.seq=p.seq;}}else if(event==='sync_complete'){this.call('sync_ack',{sync_id:p.sync_id,last_seq:this.seq}).then(()=>this.synced=true);}};
  await new Promise((resolve,reject)=>{this.ws.onopen=resolve;this.ws.onerror=reject;});
  const j=await this.call('phx_join',{protocol_version:1,control_generation:this.generation,recovery_epoch:replay?cachedEpoch:this.epoch,last_seq:cachedSeq,has_snapshot:replay},this.join);assert.equal(j.status,'ok');assert.equal(j.response.mode,replay?'replay':'snapshot');assert.equal(typeof j.response.base_seq,'number');await eventually(()=>this.synced);
 }
 call(event,p,ref=String(++this.ref),topic=this.topic){return new Promise((resolve,reject)=>{const timeout=setTimeout(()=>{this.pending.delete(ref);reject(Error('reply timeout '+event));},10000);this.pending.set(ref,v=>{clearTimeout(timeout);resolve(v);});this.ws.send(JSON.stringify([event==='heartbeat'?null:this.join,ref,topic,event,p]));});}
 intent(type,payload={},extra={}){return {protocol_version:1,recovery_epoch:this.epoch,command_id:randomUUID(),phase_id:this.view.room.phase_id,control_generation:this.generation,type,payload,...extra};}
 async command(type,payload={},extra={},intent=null){const c=intent??this.intent(type,payload,extra);const r=await this.call('command',c);assert.equal(r.response.status,'committed',JSON.stringify(r.response));await eventually(()=>this.seq>=r.response.receipt_seq);return {reply:r.response,intent:c};}
 async close(){this.ws?.close();}
}
const players=[];
try{
 for(let i=0;i<3;i++){const p=new Player();await p.guest();players.push(p);}
 const [a,b,c]=players;assert.equal(new Set(players.map(p=>p.user)).size,3);
 const created=await a.http('POST','/v1/rooms',{story_id:'11111111-1111-4111-8111-111111111111',command_id:randomUUID()});
 await b.http('POST','/v1/rooms/join',{invite_code:created.invite_code,command_id:randomUUID()});await c.http('POST','/v1/rooms/join',{invite_code:created.invite_code,command_id:randomUUID()});
 for(const p of players)await p.connect(created.room_id);
 const badAck=await a.call('sync_ack',{sync_id:a.frames.find(f=>f[3]==='sync_complete')[4].sync_id,last_seq:'forged'});assert.equal(badAck.status,'error');
 for(const [i,role] of ['investigator','passenger','conductor'].entries())await players[i].command('select_role',{role_code:role});
 for(const p of players)await p.command('ready',{ready:true});
 const started=await a.command('start');await eventually(()=>players.every(p=>p.view.room.phase_code==='briefing'));
 const opening=a.view.media.authorized.find(m=>m.media_id==='opening');
 const media=await a.http('POST','/v1/media/access',{room_id:a.room,asset_id:opening.asset_id,device_id:a.device,control_generation:a.generation});
 assert.equal(media.mime_type,'video/mp4');assert.equal(media.duration_ms,50000);
 const bytes=await fetch(media.url,{headers:{Range:'bytes=0-1023'}});assert.equal(bytes.status,206);assert.equal((await bytes.arrayBuffer()).byteLength,1024);
 assert.equal((await fetch(base+'/media/forged')).status,403);
 const subtitles=await fetch(media.subtitle.url);assert.equal(subtitles.status,200);assert((await subtitles.text()).startsWith('WEBVTT'));
 console.log('PASS: signed original video, byte range, authorized subtitles, forged capability rejected.');
 for(const p of players)await p.command('media_complete',{media_id:'opening',media_epoch:1,mode:'summary'});
 await eventually(()=>players.every(p=>p.view.media.authorized.length===2));
 const privateAsset=a.view.media.authorized.find(m=>m.kind==='own_role').asset_id;
 await assert.rejects(()=>b.http('POST','/v1/media/access',{room_id:b.room,asset_id:privateAsset,device_id:b.device,control_generation:b.generation}),e=>e.code==='RESOURCE_NOT_FOUND');
 const wrongTopic=await a.call('phx_join',{protocol_version:1,control_generation:a.generation},String(++a.ref),b.topic);assert.equal(wrongTopic.status,'error');

 for(const [i,role] of ['investigator','passenger','conductor'].entries())await players[i].command('media_complete',{media_id:'role_'+role,media_epoch:1,mode:'summary'});
 await eventually(()=>players.every(p=>p.view.room.phase_code==='exploration'));
 await b.close();await eventually(()=>a.view.members.find(m=>m.membership_id===b.member).online===false);
 await b.connect(created.room_id,true);await eventually(()=>players.every(p=>p.view.members.every(m=>m.online)));

 await sleep(200);const before=b.seq;await a.command('investigate',{action_id:'inspect_monitor'});await sleep(250);assert.equal(b.seq,before);assert(!JSON.stringify(b.view).includes('第七处被擦去'));assert.deepEqual(b.view.own_clues,[]);
 const shared=await a.command('share_clue',{clue_id:'C1'});
 for(let i=0;i<10;i++){await sleep(220);const r=await a.call('command',shared.intent);assert.deepEqual(r.response,shared.reply);}
 await b.command('investigate',{action_id:'inspect_phone'});assert(!JSON.stringify(a.view).includes('23:17，与旧车票一致'));
 const offer=await b.command('offer_item',{item_id:'C2',to_member:c.member},{target_version:1});
 assert.equal(b.view.visible_items[0].owner_membership_id,b.member);
 await c.command('accept_offer',{offer_id:offer.reply.result.offer_id});await eventually(()=>c.view.visible_items[0].owner_membership_id===c.member);
 await c.command('investigate',{action_id:'open_cabinet'});assert(!JSON.stringify(a.view).includes('控制柜记录证实'));
 await c.command('share_clue',{clue_id:'C3'});
 await a.command('request_hint',{hint_level:1});await eventually(()=>a.view.hints.entries.length===1,10000);assert.equal(a.view.hints.remaining,1);
 for(const p of players)await p.command('confirm_exploration_end');await eventually(()=>players.every(p=>p.view.room.exploration_step==='interlude'));
 const forbidden=await a.call('command',a.intent('investigate',{action_id:'inspect_monitor'}));assert.equal(forbidden.response.error.code,'NOT_ALLOWED');
 for(const p of players)await p.command('media_complete',{media_id:'interlude',media_epoch:1,mode:'summary'});
 await eventually(()=>players.every(p=>p.view.room.phase_code==='decision'));
 await sleep(200);const privateVoteSeq=c.seq;
 await a.command('vote',{round_id:a.view.vote_round.round_id,option_id:'publish'});await b.command('vote',{round_id:b.view.vote_round.round_id,option_id:'publish'});await sleep(200);assert.equal(c.seq,privateVoteSeq);assert.equal(c.view.own_vote,null);
 const heartbeat=await a.call('heartbeat',{},undefined,'phoenix');assert.equal(heartbeat.status,'ok');
 console.log('PASS: three identities, Phoenix join/sync/heartbeat/reconnect, private media/topic authorization, private streams, idempotency, transfer, hints, interlude, private voting. Waiting for authoritative 45-second deadline…');
 await eventually(()=>players.every(p=>p.view.room.phase_code==='ending'),48000);assert.equal(a.view.room.ending_code,'E1');assert.deepEqual(a.view.vote_round.tally,{leave:0,wait:0,publish:2});
 for(const p of players)await p.command('media_complete',{media_id:'ending_E1',media_epoch:1,mode:'summary'});await eventually(()=>players.every(p=>p.view.room.lifecycle==='finished'));
 const snap=await a.http('GET',`/v1/rooms/${a.room}/snapshot`,undefined,true);assert.equal(snap.snapshot.room.lifecycle,'finished');assert.equal(snap.base_seq,a.seq);
 mkdirSync(new URL('../.local/',import.meta.url),{recursive:true});
 writeFileSync(new URL('../.local/smoke-views.json',import.meta.url),JSON.stringify({snapshots:players.map(p=>p.view),events:players.flatMap(p=>p.events)}));
 console.log('PASS: deadline E1 settlement, ending confirmation, consistent durable snapshot. Synthetic view fixtures saved for schema validation.');
}finally{for(const p of players)await p.close();}
