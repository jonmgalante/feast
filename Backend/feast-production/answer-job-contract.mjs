// Versioned transport only. This does not alter the native model/tool contract.
export const ANSWER_JOBS=Object.freeze({version:1,contentTTL:86400000,tombstoneTTL:7*86400000,maxJobs:1024,maxContentJobs:64,maxActive:4,maxPayloadBytes:512000,maxBlobBytes:600000,chunkUnits:24000,retryMs:1500,longPollRetryMs:100,foregroundWaitMs:20000,watchdogMs:120000});
export const jobUUID=v=>typeof v==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v);
export const jobHash=v=>typeof v==='string'&&/^[a-f0-9]{64}$/.test(v);
export const jobStep=v=>Number.isInteger(v)&&v>=0&&v<12;
export const jobKey=(root,step)=>root.toLowerCase()+':'+step;
export function canonicalJSON(value){
 if(Array.isArray(value))return '['+value.map(canonicalJSON).join(',')+']';
 if(value!==null&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonicalJSON(value[k])).join(',')+'}';
 return JSON.stringify(value);
}
export async function jobDigest(value){return [...new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonicalJSON(value))))].map(x=>x.toString(16).padStart(2,'0')).join('')}
export const answerJobsEnabled=env=>env.ASK_FEAST_RECOVERY_ENABLED==='true'&&!!env.ANSWER_JOBS&&env.ENVIRONMENT==='production'&&env.OWNER_VALIDATION_ENABLED==='true'&&env.LIVE_AI==='true'&&env.ALLOW_RECONCILED_BUDGET==='true'&&env.NATIVE_RESEARCH_ENABLED==='true'&&env.ALLOW_PUBLIC_LOOKUP==='true';
