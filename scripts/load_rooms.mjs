import assert from 'node:assert/strict';
import os from 'node:os';
import {mkdirSync,writeFileSync} from 'node:fs';
import {Player} from './protocol_client.mjs';
const roomCount=Number(process.env.LOAD_ROOMS??100), duration=Number(process.env.LOAD_SECONDS??1500), rate=Number(process.env.LOAD_RATE??100);
const stormOnly=process.env.LOAD_STORM==='true';
const reconnectTasks=new Set();let reconnects=0;const stormMembers=new Set();
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const players=[], samples=[], errorCodes={};let errors=0, attempts=0, inflight=0;
let interval;
const started=Date.now();
try {
 for(let room=0;room<roomCount;room++){
  const group=[];
  for(let i=0;i<3;i++){const p=new Player();await p.guest();group.push(p);players.push(p);}
  const made=await group[0].http('POST','/api/v1/rooms',{story_id:'11111111-1111-4111-8111-111111111111',command_id:crypto.randomUUID()});
  for(const p of group.slice(1))await p.http('POST','/api/v1/rooms/join',{invite_code:made.invite_code,command_id:crypto.randomUUID()});
  for(const [i,p] of group.entries()){await p.connect(made.room_id);await p.command('select_role',{role_code:['investigator','passenger','conductor'][i]});await p.command('ready',{ready:true});}
  await group[0].command('start');
  // Stay in briefing so a 25-minute load does not depend on gameplay deadlines.
  for(const p of group)p.frames=[];
  if((room+1)%10===0) console.log(`Connected ${room+1} rooms / ${players.length} sockets`);
 }
 const begin=Date.now();let next=begin;
 interval=setInterval(()=>console.log(JSON.stringify({elapsed_s:Math.round((Date.now()-begin)/1000),attempts,errors,errorCodes,inflight})),60000);
 for(let index=0;Date.now()-begin<duration*1000;index++){
  const p=players[index%players.length];
  if(p.paused){next+=1000/rate;await sleep(Math.max(0,next-Date.now()));continue;}
  if(inflight>=rate*5) throw Error('stop condition: outstanding requests exceed five seconds of workload');
  attempts++;inflight++;const t=Date.now();
  p.command('chat_send',{text:'synthetic load '+index}).then(()=>samples.push(Date.now()-t)).catch(e=>{errors++;const key=e.code??e.message;errorCodes[key]=(errorCodes[key]??0)+1;}).finally(()=>{inflight--;p.frames=[];p.events=[];});
  next+=1000/rate;await sleep(Math.max(0,next-Date.now()));
  // Reconnect 10% of clients during the last five minutes, at most one every five seconds.
  const storm=(stormOnly || duration>=1500 && Date.now()-begin>=1200000) && index%Math.max(1,Math.round(rate*5))===0;
  if (storm || Date.now()-p.authAt>600000) {
    const target=storm?players[Math.floor(index/Math.max(1,Math.round(rate*5)))%Math.max(1,Math.ceil(players.length*.1))]:p;
    if(storm)stormMembers.add(target.member);
    if(target.paused)continue;
    target.paused=true;
    const task=(async()=>{const p=target;
      const drainUntil=Date.now()+15000;
      while(p.loadInflight>0){if(Date.now()>drainUntil)throw Error('reconnect drain timed out');await sleep(50);}
      if(Date.now()-p.authAt>600000){const auth=await p.http('POST','/api/v1/auth/refresh',{refresh_token:p.refreshToken,device_id:p.device,refresh_request_id:crypto.randomUUID()});p.token=auth.access_token;p.refreshToken=auth.refresh_token;p.authAt=Date.now();}
      await p.close();await sleep(100);await p.connect(p.room,true);reconnects++;
    })().catch(e=>{errors++;const key=e.code??e.message;errorCodes[key]=(errorCodes[key]??0)+1;}).finally(()=>{target.paused=false;reconnectTasks.delete(task);});
    reconnectTasks.add(task);
  }
  if(attempts>1000 && errors/attempts>0.01)throw Error('stop condition: error rate exceeds 1% '+JSON.stringify(errorCodes));
 }
 clearInterval(interval);
 for(let i=0;i<200&&inflight;i++)await sleep(100);
 await Promise.allSettled([...reconnectTasks]);
 samples.sort((a,b)=>a-b);const percentile=q=>samples[Math.floor((samples.length-1)*q)];
 const report={date:new Date().toISOString(),host:{platform:os.platform(),release:os.release(),cpu:os.cpus()[0].model,logical_cpus:os.cpus().length,memory_bytes:os.totalmem()},rooms:roomCount,sockets:players.length,requested_rate:rate,duration_s:duration,attempts,errors,errorCodes,reconnections:reconnects,storm_distinct_members:stormMembers.size,storm_only:stormOnly,successful:samples.length,projection_gaps_repaired:players.reduce((n,p)=>n+p.gaps,0),round_trip_and_local_view_apply_ms:{p50:percentile(.5),p95:percentile(.95),p99:percentile(.99)},total_elapsed_s:(Date.now()-started)/1000,limitations:['Loopback HTTP/WS; no TLS proxy, WAN, phone rendering or video traffic.','Measured intent-to-receipt/local projection application, not isolated commit-to-other-client latency.','Briefing chat workload; media confirmation and voting races covered separately.']};
 mkdirSync('.local',{recursive:true});writeFileSync(process.env.LOAD_REPORT??'.local/load-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 assert.equal(errors,0);
}finally{clearInterval(interval);for(const p of players)await p.close();}
