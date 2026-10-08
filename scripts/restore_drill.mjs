import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdirSync,chmodSync,writeFileSync,existsSync} from 'node:fs';
const base=process.env.API_BASE??'http://localhost:4000';
const pg=process.env.PG_BIN ? process.env.PG_BIN.replace(/\/?$/, '/') : existsSync('/opt/homebrew/opt/postgresql@17/bin/pg_dump') ? '/opt/homebrew/opt/postgresql@17/bin/' : '';
const db='ruxi_drill_'+randomUUID().replaceAll('-','');
const core=new URL('../services/core/',import.meta.url);
const backup=new URL('../.local/backups/restore-drill.dump',import.meta.url).pathname;
const ledger=new URL('../.local/erasure-ledger.jsonl',import.meta.url).pathname;
mkdirSync(new URL('../.local/backups/',import.meta.url),{recursive:true});
const guest=await (await fetch(base+'/v1/auth/guest',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({device_id:randomUUID(),command_id:randomUUID()})})).json();assert.ok(guest.data);
const started=Date.now();
execFileSync(pg+'pg_dump',['-h','localhost','-p','55432','-d','ruxi_dev','-n','ruxi','-Fc','-f',backup]);chmodSync(backup,0o600);
const snapshotAt=Date.now();
const erase=await fetch(base+'/v1/me/erase',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+guest.data.access_token},body:JSON.stringify({command_id:randomUUID(),confirmation:'ERASE_ACCOUNT'})});assert.ok(erase.ok);
try {
 execFileSync(pg+'createdb',['-h','localhost','-p','55432',db]);
 execFileSync(pg+'pg_restore',['-h','localhost','-p','55432','-d',db,'--no-owner','--no-privileges',backup]);
 const epoch='restore-drill-'+randomUUID();
 execFileSync('mix',['run','--no-start','priv/repo/recover_database.exs'],{cwd:core,encoding:'utf8',env:{...process.env,DATABASE_URL:'postgres://localhost:55432/'+db,RECOVERY_EPOCH:epoch,CORE_INSTANCE:epoch,PHX_SERVER:'false',ERASURE_LEDGER_PATH:ledger,RECOVERY_CONFIRMATION:'RESET_RESTORED_DATABASE'}});
 const output=execFileSync('mix',['run',new URL('./restore_verify.exs',import.meta.url).pathname],{cwd:core,encoding:'utf8',env:{...process.env,DATABASE_URL:'postgres://localhost:55432/'+db,RECOVERY_EPOCH:epoch,CORE_INSTANCE:epoch,PHX_SERVER:'false',ERASURE_LEDGER_PATH:ledger,DRILL_ERASED_USER:guest.data.user_id}});
 const verified=JSON.parse(output.trim().split('\n').at(-1));assert.equal(verified.verified,true);
 const report={date:new Date().toISOString(),backup_age_at_restore_seconds:(Date.now()-snapshotAt)/1000,total_drill_seconds:(Date.now()-started)/1000,backup_completed_at:new Date(snapshotAt).toISOString(),checks:verified,limitations:['Local isolated PostgreSQL restore, same host and PG role.','This measures one exercise; cloud scheduled backup, external ledger durability and WAL recovery need deployment validation.']};
 writeFileSync(new URL('../.local/restore-report.json',import.meta.url),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{execFileSync(pg+'dropdb',['-h','localhost','-p','55432','--if-exists',db]);}
