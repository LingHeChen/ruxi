import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {writeFileSync,mkdirSync} from 'node:fs';
import {Player} from './protocol_client.mjs';
const players=[];const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const eventually=async fn=>{for(let i=0;i<200;i++){if(fn())return;await sleep(25);}throw Error('race view did not converge');};
try{
 for(let i=0;i<3;i++){const p=new Player();await p.guest();players.push(p);}
 const[a,b,c]=players;const room=await a.http('POST','/v1/rooms',{story_id:'11111111-1111-4111-8111-111111111111',command_id:randomUUID()});
 for(const p of [b,c])await p.http('POST','/v1/rooms/join',{invite_code:room.invite_code,command_id:randomUUID()});
 for(const p of players)await p.connect(room.room_id);
 const selections=await Promise.all([a.call('command',a.intent('select_role',{role_code:'investigator'})),b.call('command',b.intent('select_role',{role_code:'investigator'}))]);
 assert.equal(selections.filter(r=>r.response.status==='committed').length,1);
 await eventually(()=>players.every(p=>p.view.members.filter(m=>m.role_code==='investigator').length===1));
 const investigator=selections[0].response.status==='committed'?a:b,passenger=investigator===a?b:a,conductor=c;
 await passenger.command('select_role',{role_code:'passenger'});await conductor.command('select_role',{role_code:'conductor'});
 for(const p of players)await p.command('ready',{ready:true});
 const start=a.intent('start');const starts=await Promise.all([a.call('command',start),a.call('command',start)]);assert.deepEqual(starts[0].response,starts[1].response);assert.equal(starts[0].response.status,'committed');
 await eventually(()=>players.every(p=>p.view.room.phase_code==='briefing'));
 for(const p of players)await p.command('media_complete',{media_id:'opening',media_epoch:1,mode:'summary'});
 for(const p of players)await p.command('media_complete',{media_id:'role_'+p.view.self.role_code,media_epoch:1,mode:'summary'});
 await eventually(()=>players.every(p=>p.view.room.phase_code==='exploration'));
 await sleep(500);await passenger.command('investigate',{action_id:'inspect_phone'});
 const offer=await passenger.command('offer_item',{item_id:'C2',to_member:conductor.member},{target_version:1});
 const accept=conductor.intent('accept_offer',{offer_id:offer.reply.result.offer_id}),cancel=passenger.intent('cancel_offer',{offer_id:offer.reply.result.offer_id});
 const resolutions=await Promise.all([conductor.call('command',accept),passenger.call('command',cancel)]);
 assert.equal(resolutions.filter(r=>r.response.status==='committed').length,1);
 assert.equal(resolutions.find(r=>r.response.status!=='committed').response.error.code,'TARGET_CHANGED');
 let accepted=accept;
 if(resolutions[0].response.status!=='committed'){
  const next=await passenger.command('offer_item',{item_id:'C2',to_member:conductor.member},{target_version:1});accepted=conductor.intent('accept_offer',{offer_id:next.reply.result.offer_id});
 }
 await sleep(500);const duplicates=await Promise.all([conductor.call('command',accepted),conductor.call('command',accepted)]);assert.deepEqual(duplicates[0].response,duplicates[1].response);assert.equal(duplicates[0].response.status,'committed');
 await eventually(()=>conductor.view.visible_items.some(i=>i.item_id==='C2'&&i.owner_membership_id===conductor.member&&i.version===2));
 const snapshot=await conductor.http('GET',`/v1/rooms/${room.room_id}/snapshot`,undefined,true);const item=snapshot.snapshot.visible_items.find(i=>i.item_id==='C2');assert.equal(item.version,2);assert.equal(item.owner_membership_id,conductor.member);
 assert.ok(!JSON.stringify(investigator.view.own_clues).includes('23:17，与旧车票一致'));
 const report={date:new Date().toISOString(),passed:true,checks:['simultaneous unique-role selection','concurrent exact-ID start replay','accept versus cancel: exactly one committed outcome','concurrent duplicate acceptance: exact receipt and one ownership increment','private discovery remains isolated']};mkdirSync('.local',{recursive:true});writeFileSync('.local/race-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{for(const p of players)await p.close();}
