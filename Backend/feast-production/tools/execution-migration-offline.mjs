#!/usr/bin/env node
// Offline only. Never reads credentials, invokes wrangler, or contacts a service.
import {readFile,writeFile} from 'node:fs/promises';
import {resolve} from 'node:path';
import {executionInventory,applyExecutionMigration} from '../execution-migration.mjs';
const [mode,input,planPath,output]=process.argv.slice(2);
if(!['inventory','apply'].includes(mode)||!input||mode==='apply'&&(!planPath||!output)||mode==='inventory'&&(planPath||output)){
 console.error('Usage: node execution-migration-offline.mjs inventory SNAPSHOT.json\n       node execution-migration-offline.mjs apply SNAPSHOT.json REVIEWED_PLAN.json NEW_SNAPSHOT.json');process.exit(2);
}
try{
 const bytes=await readFile(input,'utf8'),snapshot=JSON.parse(bytes);
 if(!snapshot||snapshot.version!==1||!Array.isArray(snapshot.entries)||snapshot.entries.some(x=>!Array.isArray(x)||x.length!==2||typeof x[0]!=='string'||!/^production-validation-v[12]:/.test(x[0]))||new Set(snapshot.entries.map(x=>x[0])).size!==snapshot.entries.length)throw Error('offline_snapshot_invalid');
 let data=new Map(snapshot.entries);
 const storage={transaction:async fn=>{const next=structuredClone(data),tx={get:async k=>structuredClone(next.get(k)),put:async(k,v)=>{if(new TextEncoder().encode(JSON.stringify(v)).length>=128*1024)throw Error('offline_value_limit');next.set(k,structuredClone(v))},list:async({prefix='',limit=1000,startAfter}={})=>new Map([...next].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a<b?-1:a>b?1:0).slice(0,limit))};const result=await fn(tx);data=next;return result}};
 if(mode==='inventory')console.log(JSON.stringify(await executionInventory(storage),null,2));
 else{
  if([input,planPath].some(p=>resolve(p)===resolve(output)))throw Error('offline_output_must_be_new');
  const receipt=await applyExecutionMigration(storage,JSON.parse(await readFile(planPath,'utf8')));
  // Source and reviewed plan are immutable inputs. Exclusive creation prevents
  // overwriting any original snapshot, receipt, ledger export or prior result.
  await writeFile(output,JSON.stringify({version:1,entries:[...data]},null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({offline:true,liveChanges:false,receipt},null,2));
 }
}catch(error){console.error(/^[a-z_]+$/.test(error.message)?error.message:'offline_migration_failed');process.exitCode=1}
