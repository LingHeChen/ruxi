import test from 'node:test';
import assert from 'node:assert/strict';
import {Player} from './protocol_client.mjs';
const event=(seq,title)=>({seq,payload:{replace:{room:{title}}}});
test('projection waits for a gap and ignores duplicate historical delivery',()=>{
 const p=new Player();p.view={room:{title:'baseline'},private:{clues:['owned']}};
 p.ingest(event(2,'second'));assert.equal(p.seq,0);assert.equal(p.view.room.title,'baseline');
 p.ingest(event(1,'first'));assert.equal(p.seq,2);assert.equal(p.view.room.title,'second');assert.deepEqual(p.view.private.clues,['owned']);assert.equal(p.buffer.size,0);
 p.ingest(event(1,'stale'));assert.equal(p.view.room.title,'second');
});
test('persistent projection gap has a bounded buffer',()=>{
 const p=new Player();p.view={};for(let seq=2;seq<=201;seq++)p.ingest(event(seq,'future'));
 assert.throws(()=>p.ingest(event(202,'overflow')),/bounded buffer/);assert.equal(p.seq,0);
});

test('in-flight accounting stays with the actor when the caller changes reconnect target',async()=>{
 const first=new Player(),second=new Player();let finishFirst,finishSecond;
 first.call=()=>new Promise(r=>finishFirst=r);second.call=()=>new Promise(r=>finishSecond=r);
 let target=first;const a=target.command('start',{}, {}, {});target=second;const b=target.command('start',{}, {}, {});
 assert.equal(first.loadInflight,1);assert.equal(second.loadInflight,1);
 finishSecond({response:{status:'committed',receipt_seq:0}});await b;
 assert.equal(second.loadInflight,0);assert.equal(first.loadInflight,1);
 finishFirst({response:{error:{code:'TARGET_CHANGED'}}});await assert.rejects(a,e=>e.code==='TARGET_CHANGED');
 assert.equal(first.loadInflight,0);
});
