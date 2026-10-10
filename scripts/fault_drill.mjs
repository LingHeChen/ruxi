import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {mkdirSync,openSync,closeSync,writeFileSync,existsSync} from 'node:fs';
const db='ruxi_fault_'+randomUUID().replaceAll('-',''), pg=process.env.PG_BIN ? process.env.PG_BIN.replace(/\/?$/, '/') : existsSync('/opt/homebrew/opt/postgresql@17/bin/pg_dump') ? '/opt/homebrew/opt/postgresql@17/bin/' : '';
const root=new URL('../',import.meta.url), core=new URL('../services/core/',import.meta.url);
const env={...process.env,DATABASE_URL:'postgres://localhost:55432/'+db,RECOVERY_EPOCH:'fault-drill',CORE_INSTANCE:'fault-core',PORT:'4003',PHX_SERVER:'false',ERASURE_LEDGER_PATH:new URL('../.local/fault-erasure.jsonl',import.meta.url).pathname};
mkdirSync(new URL('../.local/',import.meta.url),{recursive:true});
const log=openSync(new URL('../.local/fault-core.log',import.meta.url),'a',0o600);
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
let processCore;const players=[];
async function start(){processCore=spawn('mix',['run','--no-halt'],{cwd:core,env:{...env,PHX_SERVER:'true'},stdio:['ignore',log,log]});for(let i=0;i<100;i++){try{if((await fetch('http://localhost:4003/api/health')).ok)return;}catch{}await sleep(100);}throw Error('isolated Core did not start');}
try {
 execFileSync(pg+'createdb',['-h','localhost','-p','55432',db]);
 for(const args of [['run','--no-start','priv/repo/init_schema.exs'],['ecto.migrate'],['run','priv/repo/seeds.exs']])execFileSync('mix',args,{cwd:core,env,stdio:['ignore','ignore','inherit']});
 await start();process.env.API_BASE='http://localhost:4003';const{Player}=await import('./protocol_client.mjs');
 for(let i=0;i<3;i++){const p=new Player();await p.guest();players.push(p);}
 const[a,b,c]=players;const made=await a.http('POST','/api/v1/rooms',{story_id:'11111111-1111-4111-8111-111111111111',command_id:randomUUID()});
 for(const p of [b,c])await p.http('POST','/api/v1/rooms/join',{invite_code:made.invite_code,command_id:randomUUID()});
 for(const[i,p]of players.entries()){await p.connect(made.room_id);await p.command('select_role',{role_code:['investigator','passenger','conductor'][i]});await p.command('ready',{ready:true});}
 await a.command('start');
 for(const p of players)await p.command('media_complete',{media_id:'opening',media_epoch:1,mode:'summary'});
 for(const[i,p]of players.entries())await p.command('media_complete',{media_id:'role_'+['investigator','passenger','conductor'][i],media_epoch:1,mode:'summary'});
 await a.command('investigate',{action_id:'inspect_monitor'});
 const intent=a.intent('share_clue',{clue_id:'C1'});
 // Lose the response independently of whether the first write reaches commit.
 const lost=a.call('command',intent).catch(()=>null);
 await sleep(5);processCore.kill('SIGKILL');await new Promise(r=>processCore.once('exit',r));
 for(const p of players)await p.close();await start();
 for(const p of players)await p.connect(made.room_id,true);
 const retried=await a.command('share_clue',{clue_id:'C1'},{},intent);
 const duplicate=await a.call('command',intent);assert.deepEqual(duplicate.response,retried.reply);
 await lost;
 assert.equal(a.view.public_scene.shared_clues.filter(x=>x.clue_id==='C1').length,1);
 assert.equal(b.view.own_clues.length,0);
 const facts=execFileSync('psql',['-h','localhost','-p','55432','-d',db,'-At','-c',`SELECT count(*) FROM ruxi.room_commands WHERE command_id='${intent.command_id}'`],{encoding:'utf8'}).trim();assert.equal(facts,'1');
 const report={date:new Date().toISOString(),checks:['SIGKILL during command response','restart and durable replay of three role views','same-command retry and exact receipt','one committed command row','private clue remains isolated'],passed:true};
 writeFileSync(new URL('../.local/fault-report.json',import.meta.url),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{
 for(const p of players)await p.close();
 if(processCore&&processCore.exitCode===null){processCore.kill('SIGTERM');await new Promise(r=>processCore.once('exit',r));}
 closeSync(log);execFileSync(pg+'dropdb',['-h','localhost','-p','55432','--if-exists',db]);
}
