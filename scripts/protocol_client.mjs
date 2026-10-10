import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
const base=process.env.API_BASE ?? 'http://localhost:4000';
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function eventually(fn,timeout=10000){const end=Date.now()+timeout;while(Date.now()<end){if(await fn())return;await sleep(30);}throw Error('condition timed out');}
export class Player{
 constructor(){this.device=randomUUID();this.ref=0;this.pending=new Map();this.view=null;this.seq=0;this.events=[];this.frames=[];this.synced=false;this.buffer=new Map();this.gaps=0;this.loadInflight=0;}
 async http(method,path,body,privateRead=false){const r=await fetch(base+path,{method,headers:{'Content-Type':'application/json',...(this.token?{'Authorization':'Bearer '+this.token}:{}),...(privateRead?{'X-Device-ID':this.device,'X-Control-Generation':String(this.generation)}:{})},...(method==='GET'?{}:{body:JSON.stringify(body)})});const v=await r.json();if(r.status>=400)throw Object.assign(Error(v.error.code),{code:v.error.code});return v.data;}
 async guest(){const a=await this.http('POST','/api/v1/auth/guest',{device_id:this.device,command_id:randomUUID()});this.token=a.access_token;this.refreshToken=a.refresh_token;this.authAt=Date.now();this.user=a.user_id;}
 async connect(room,replay=false){const cachedSeq=replay?this.seq:0;const cachedEpoch=this.epoch;this.synced=false;this.room=room;const t=await this.http('POST',`/api/v1/rooms/${room}/socket-ticket`,{device_id:this.device,takeover:false});this.member=t.membership_id;this.generation=t.control_generation;this.epoch=t.recovery_epoch;this.topic=`player_room:${room}:${this.member}`;this.ws=new WebSocket(base.replace(/^http/,'ws')+`/api/socket/websocket?vsn=2.0.0&ticket=${t.socket_ticket}`);this.join='j'+(++this.ref);
  const ws=this.ws;this.buffer.clear();this.ws.onmessage=({data})=>{if(this.ws!==ws)return;const f=JSON.parse(data);this.frames.push(f);const [_,ref,topic,event,p]=f;if(event==='phx_reply'){const c=this.pending.get(ref);if(c){this.pending.delete(ref);c(p);}}else if(event==='sync_snapshot'){this.view=p.snapshot;this.seq=p.base_seq;this.epoch=p.recovery_epoch;}else if(event==='view_event'){this.ingest(p);if(p.seq>this.seq){this.gaps++;this.repair().catch(e=>this.protocolError=e);}}else if(event==='sync_complete'){(async()=>{if(this.seq<p.through_seq)await this.repair();await eventually(()=>this.seq>=p.through_seq);await this.call('sync_ack',{sync_id:p.sync_id,last_seq:this.seq});this.synced=true;})().catch(e=>this.protocolError=e);}else if(event==='watermark'&&p.view_seq>this.seq){this.repair().catch(e=>this.protocolError=e);}};
  await new Promise((resolve,reject)=>{this.ws.onopen=resolve;this.ws.onerror=reject;});
  const j=await this.call('phx_join',{protocol_version:1,control_generation:this.generation,recovery_epoch:replay?cachedEpoch:this.epoch,last_seq:cachedSeq,has_snapshot:replay},this.join);assert.equal(j.status,'ok',JSON.stringify(j));assert.equal(j.response.mode,replay?'replay':'snapshot');assert.equal(typeof j.response.base_seq,'number');await eventually(()=>this.synced);clearInterval(this.heartbeatTimer);this.heartbeatTimer=setInterval(()=>this.call('heartbeat',{},String(++this.ref),'phoenix').catch(()=>{}),25000);
 }
 ingest(event){
  this.events.push(event);if(event.seq<=this.seq)return;
  this.buffer.set(event.seq,event);assert.ok(this.buffer.size<=200,'projection gap exceeded bounded buffer');
  while(this.buffer.has(this.seq+1)){const e=this.buffer.get(this.seq+1);this.buffer.delete(this.seq+1);this.view={...this.view,...e.payload.replace};this.seq=e.seq;}
 }
 async repair(){
  if(this.repairing)return this.repairing;
  this.repairing=(async()=>{let more=true;while(more){const page=await this.http('GET',`/api/v1/rooms/${this.room}/events?after_seq=${this.seq}&recovery_epoch=${encodeURIComponent(this.epoch)}`,undefined,true);for(const e of page.events)this.ingest(e);more=page.has_more;}})();
  try{await this.repairing;}finally{this.repairing=null;}
 }
 call(event,p,ref=String(++this.ref),topic=this.topic){return new Promise((resolve,reject)=>{const timeout=setTimeout(()=>{this.pending.delete(ref);reject(Error('reply timeout '+event));},10000);this.pending.set(ref,v=>{clearTimeout(timeout);resolve(v);});this.ws.send(JSON.stringify([event==='heartbeat'?null:this.join,ref,topic,event,p]));});}
 intent(type,payload={},extra={}){return {protocol_version:1,recovery_epoch:this.epoch,command_id:randomUUID(),phase_id:this.view.room.phase_id,control_generation:this.generation,type,payload,...extra};}
 async command(type,payload={},extra={},intent=null){
  this.loadInflight++;
  try{
   if(this.protocolError)throw this.protocolError;
   const c=intent??this.intent(type,payload,extra);const r=await this.call('command',c);
   if(r.response.error)throw Object.assign(Error(r.response.error.code),{code:r.response.error.code});
   assert.equal(r.response.status,'committed',JSON.stringify(r.response));
   await eventually(()=>this.seq>=r.response.receipt_seq);return {reply:r.response,intent:c};
  }finally{this.loadInflight--;}
 }

 async close(){clearInterval(this.heartbeatTimer);this.ws?.close();}
}
