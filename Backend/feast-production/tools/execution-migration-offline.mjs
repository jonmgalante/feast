#!/usr/bin/env node
// Offline only. Never reads credentials, invokes wrangler, or contacts a service.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {buildAccountingIndex,auditAccountingIndex,prepareAccountingIndexPlan,beginAccountingIndex,advanceAccountingIndex,activateAccountingIndex,accountingIndexStatus} from '../accounting-index.mjs';
import {jobDigest} from '../answer-job-contract.mjs';
import {executionInventory,applyExecutionMigration} from '../execution-migration.mjs';
const [mode,input,planPath,output]=process.argv.slice(2);
const writes=['apply','index','index-plan','index-begin','index-step','index-activate'],reads=['inventory','audit','index-status'];
if(![...reads,...writes].includes(mode)||!input||writes.includes(mode)&&(!planPath||!output)||reads.includes(mode)&&(planPath||output)){
 console.error('Usage: node execution-migration-offline.mjs inventory SNAPSHOT.json\n       node execution-migration-offline.mjs apply SNAPSHOT.json REVIEWED_PLAN.json NEW_SNAPSHOT.json\n       node execution-migration-offline.mjs index SNAPSHOT.json REVIEWED_INDEX_PLAN.json NEW_SNAPSHOT.json\n       node execution-migration-offline.mjs audit INDEXED_SNAPSHOT.json\n       index-plan SNAPSHOT.json REVIEWED_EVIDENCE.json NEW_PLAN.json\n       index-begin SNAPSHOT.json REVIEWED_PLAN.json NEW_SNAPSHOT.json\n       index-step SNAPSHOT.json EXPECTED_STEP.json NEW_SNAPSHOT.json\n       index-activate SNAPSHOT.json TOKEN.json NEW_SNAPSHOT.json\n       index-status SNAPSHOT.json');process.exit(2);
}
try{
 const bytes=await readFile(input,'utf8'),snapshot=JSON.parse(bytes);
 if(!snapshot||snapshot.version!==1||!Array.isArray(snapshot.entries)||snapshot.entries.some(x=>!Array.isArray(x)||x.length!==2||typeof x[0]!=='string'||!/^production-validation-v[12]:/.test(x[0]))||new Set(snapshot.entries.map(x=>x[0])).size!==snapshot.entries.length)throw Error('offline_snapshot_invalid');
 if(snapshot.alarm!==undefined&&snapshot.alarm!==null&&(!Number.isSafeInteger(snapshot.alarm)||snapshot.alarm<0))throw Error('offline_alarm_invalid');
 let data=new Map(snapshot.entries),alarm=snapshot.alarm??null;
 const storage={transaction:async fn=>{const next=structuredClone(data);let nextAlarm=alarm;const tx={get:async k=>structuredClone(next.get(k)),put:async(k,v)=>{if(new TextEncoder().encode(JSON.stringify(v)).length>=128*1024)throw Error('offline_value_limit');next.set(k,structuredClone(v))},delete:async k=>next.delete(k),getAlarm:async()=>nextAlarm,setAlarm:async n=>{nextAlarm=n},deleteAlarm:async()=>{nextAlarm=null},list:async({prefix='',limit=1000,startAfter}={})=>new Map([...next].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a<b?-1:a>b?1:0).slice(0,limit))};const result=await fn(tx);data=next;alarm=nextAlarm;return result}};
 if(mode==='audit')console.log(JSON.stringify({...await auditAccountingIndex(storage),immutableSnapshotDigest:await jobDigest(snapshot)},null,2));
 else if(mode==='index-status')console.log(JSON.stringify(await accountingIndexStatus(storage),null,2));
 else if(mode==='inventory')console.log(JSON.stringify(await executionInventory(storage),null,2));
 else{
  if([input,planPath].some(p=>resolve(p)===resolve(output)))throw Error('offline_output_must_be_new');
  const plan=JSON.parse(await readFile(planPath,'utf8')),action={apply:applyExecutionMigration,index:buildAccountingIndex,'index-plan':prepareAccountingIndexPlan,'index-begin':beginAccountingIndex,'index-step':advanceAccountingIndex,'index-activate':(s,p)=>activateAccountingIndex(s,p.token)}[mode],receipt=await action(storage,plan);
  // Source and reviewed plan are immutable inputs. Exclusive creation prevents
  // overwriting any original snapshot, receipt, ledger export or prior result.
  await writeFile(output,JSON.stringify(mode==='index-plan'?receipt:{version:1,entries:[...data],alarm},null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({offline:true,liveChanges:false,receipt},null,2));
 }
}catch(error){console.error(/^[a-z_]+$/.test(error.message)?error.message:'offline_migration_failed');process.exitCode=1}
