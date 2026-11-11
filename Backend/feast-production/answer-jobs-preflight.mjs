// Offline rollout evidence. Completeness/quiescence and never-enabled history
// are reviewed operational attestations; no local snapshot can establish them.
import {jobDigest,jobHash,jobKey,jobUUID,jobStep} from './answer-job-contract.mjs';
const identity=x=>x&&x.version===1&&x.namespace==='answer-jobs-v1'&&/^[a-f0-9]{32}$/.test(x.namespaceID??'')&&/^[a-f0-9]{40}$/.test(x.sourceRevision??'')&&jobHash(x.quiescenceRevision)&&jobHash(x.evidenceDigest);
const phases=['accepted','preparing','reserving','reserved','claiming','claimed','dispatched','received','settling','done'];
const states=['queued','running','completed','failed','uncertain','cancelled','expired','acknowledged'];
export async function answerJobsPreflight(snapshot){
 if(!identity(snapshot)||snapshot.writersQuiesced!==true||snapshot.namespaceComplete!==true||!Array.isArray(snapshot.objects)||snapshot.objectCount!==snapshot.objects.length||new Set(snapshot.objects.map(o=>o.id)).size!==snapshot.objects.length)throw Error('recovery_inventory_incomplete');
 const jobs=[];let claims=0;
 for(const object of snapshot.objects){
  if(!jobHash(object.id)||object.complete!==true||object.nextCursor!==null||!Array.isArray(object.entries)||object.entries.some(x=>!Array.isArray(x)||x.length!==2||typeof x[0]!=='string')||new Set(object.entries.map(x=>x[0])).size!==object.entries.length)throw Error('recovery_inventory_incomplete');
  for(const [key,j] of object.entries){
   if(key.startsWith('content:')){const m=/^content:([a-f0-9-]{36}:[0-9]+):(payload|provider|reply|dispatch-provider|dispatch-count):[0-9]{3}$/.exec(key);if(!m||typeof j!=='string'||!object.entries.some(([k])=>k==='job:'+m[1]))throw Error('recovery_inventory_unknown');continue}
   if(key.startsWith('cancel-claim:')){if(!j||!jobUUID(j.requestID)||!jobStep(j.step)||key!=='cancel-claim:'+jobKey(j.requestID,j.step)||!jobHash(j.userHash))throw Error('recovery_inventory_unknown');claims++;continue}
   if(!key.startsWith('job:')||!j||!jobUUID(j.requestID)||!jobStep(j.step)||key!=='job:'+jobKey(j.requestID,j.step)||j.key!==jobKey(j.requestID,j.step)||!jobHash(j.userHash)||!phases.includes(j.phase)||!states.includes(j.state)||j.phase==='done'&&['queued','running'].includes(j.state))throw Error('recovery_inventory_unknown');
   const active=j.phase!=='done'||j.needsFence===true||j.reservation||j.reserveIntent||j.settlement&&!j.settled;
   const preproof=active&&(j.reservation||j.reserveIntent)&&!jobHash(j.reservation?.bodyDigest??j.reserveIntent?.bodyDigest)&&!j.dispatchMaterial;
   jobs.push({objectID:object.id,keyDigest:await jobDigest(key),recordDigest:await jobDigest(j),phase:j.phase,state:j.state,category:preproof?'preproof-reservation':active?'active':'terminal'});
  }
 }
 jobs.sort((a,b)=>a.objectID.localeCompare(b.objectID)||a.keyDigest.localeCompare(b.keyDigest));
 return {version:1,namespace:snapshot.namespace,namespaceID:snapshot.namespaceID,sourceRevision:snapshot.sourceRevision,quiescenceRevision:snapshot.quiescenceRevision,evidenceDigest:snapshot.evidenceDigest,namespaceComplete:true,objectCount:snapshot.objects.length,objectIDs:snapshot.objects.map(o=>o.id).sort(),snapshotDigest:await jobDigest(snapshot),jobs,claims,ready:claims===0&&jobs.every(j=>j.category==='terminal')};
}
export async function validateRecoveryDisposition(d){
 if(d?.version!==1)throw Error('migration_recovery_disposition_required');
 if(d.kind==='never-enabled'){if(!identity(d))throw Error('migration_recovery_evidence_required');return}
 if(d.kind!=='drained'||!identity(d.artifact)||!jobHash(d.artifactDigest)||await jobDigest(d.artifact)!==d.artifactDigest)throw Error('migration_recovery_artifact_invalid');
 const a=d.artifact;
 if(a.namespaceComplete!==true||!Array.isArray(a.objectIDs)||a.objectCount!==a.objectIDs.length||new Set(a.objectIDs).size!==a.objectIDs.length||a.objectIDs.some(id=>!jobHash(id))||!jobHash(a.snapshotDigest)||!Array.isArray(a.jobs)||a.claims!==0||a.ready!==true||a.jobs.some(j=>!a.objectIDs.includes(j.objectID)||!jobHash(j.keyDigest)||!jobHash(j.recordDigest)||j.phase!=='done'||!states.includes(j.state)||['queued','running'].includes(j.state)||j.category!=='terminal')||new Set(a.jobs.map(j=>j.objectID+':'+j.keyDigest)).size!==a.jobs.length)throw Error('migration_recovery_not_drained');
}
