// Verify the OTP release against a fresh isolated database, never a live room database.
import assert from 'node:assert/strict';
import {randomUUID,randomBytes} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {existsSync,mkdirSync,openSync,closeSync,writeFileSync} from 'node:fs';
const pg=process.env.PG_BIN?process.env.PG_BIN.replace(/\/?$/,'/'):existsSync('/opt/homebrew/opt/postgresql@17/bin/pg_dump')?'/opt/homebrew/opt/postgresql@17/bin/':'';
const db='ruxi_release_'+randomUUID().replaceAll('-',''),core=new URL('../services/core/',import.meta.url);
const env={...process.env,MIX_ENV:'dev',DATABASE_URL:'postgres://localhost:55432/'+db,PHX_SERVER:'false'};
mkdirSync('.local',{recursive:true});const log=openSync('.local/release-check.log','w',0o600);let server;
try{
 execFileSync(pg+'createdb',['-h','localhost','-p','55432',db]);
 for(const args of [['run','--no-start','priv/repo/init_schema.exs'],['ecto.migrate'],['run','priv/repo/seeds.exs']])execFileSync('mix',args,{cwd:core,env,stdio:'ignore'});
 const runtime={...env,MIX_ENV:'prod',PHX_SERVER:'true',PORT:'4005',SECRET_KEY_BASE:randomBytes(64).toString('hex'),RECOVERY_EPOCH:'release-'+randomUUID(),CORE_INSTANCE:'release-isolated',ERASURE_LEDGER_PATH:new URL('../.local/release-erasure.jsonl',import.meta.url).pathname,OBJECT_ROOT:new URL('../.local/objects/',import.meta.url).pathname,WORKER_CREDENTIALS_JSON:JSON.stringify([{worker_id:'release-worker',token:randomBytes(32).toString('hex'),allowed_kinds:['player_hint']}]),PUBLIC_API_URL:'https://example.invalid',ALLOWED_ORIGINS:'https://example.invalid'};
 server=spawn('_build/prod/rel/ruxi/bin/ruxi',['start'],{cwd:core,env:runtime,stdio:['ignore',log,log]});
 let healthy=false;for(let i=0;i<100;i++){if(server.exitCode!==null)throw Error('release exited; see ignored .local/release-check.log');try{healthy=(await fetch('http://localhost:4005/api/health')).status===200;if(healthy)break;}catch{}await new Promise(r=>setTimeout(r,100));}
 assert.ok(healthy,'production health did not succeed');
 const report={date:new Date().toISOString(),passed:true,checks:['fresh isolated ruxi schema migrations and seed','strict production runtime configuration','OTP release process /api/health HTTP 200'],limitations:['Local release, not a container or CloudBase deployment.']};writeFileSync('.local/release-report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{
 if(server&&server.exitCode===null){server.kill('SIGTERM');await new Promise(r=>server.once('exit',r));}
 closeSync(log);execFileSync(pg+'dropdb',['-h','localhost','-p','55432','--if-exists',db]);
}
