import {DIRECT_NATIVE_LIMITS} from '../feast-production/native-research.mjs';
import {ACTIVE_MODEL} from '../feast-production/active-model.mjs';
import {VALIDATION_CAP_MICRO_USD} from '../feast-production/budget-policy.mjs';
import {digest,json} from '../feast-production/broker.mjs';
function same(a,b){if(typeof a!=='string'||typeof b!=='string'||a.length!==b.length)return false;let d=0;for(let i=0;i<a.length;i++)d|=a.charCodeAt(i)^b.charCodeAt(i);return d===0}
export async function ownerIdentity(token,recordJSON,now=Date.now()){
 if(typeof token!=='string'||!/^[A-Za-z0-9_-]{43}$/.test(token))return null;
 try{const records=JSON.parse(recordJSON);if(!Array.isArray(records)||records.length!==1)return null;const r=records[0];
  if(!r||Object.keys(r).sort().join(',')!=='createdAt,expiresAt,id,sha256'||r.id!=='owner-original-iphone17'||!/^[a-f0-9]{64}$/.test(r.sha256??'')||!Number.isFinite(Date.parse(r.createdAt))||!Number.isFinite(Date.parse(r.expiresAt))||Date.parse(r.createdAt)>now||Date.parse(r.expiresAt)<=now||Date.parse(r.expiresAt)-Date.parse(r.createdAt)>30*24*3600*1000)return null;
  return same(await digest(token),r.sha256)?await digest('production-owner:'+r.id):null;
 }catch{return null}
}
export default {
 async fetch(request,env){
  const path=new URL(request.url).pathname;
  if(path==='/health'&&request.method==='GET')return json({service:'feast-owner-validation',requestsEnabled:env.ENABLED==='true'&&env.LIVE_AI==='true',liveAI:env.ENABLED==='true'&&env.LIVE_AI==='true',savedMetadataEnabled:true,savedToolsEnabled:env.ENABLED==='true'&&env.LIVE_AI==='true',savedToolsVersion:3,collectionContextVersion:1,...(env.NATIVE_RESEARCH_ENABLED==='true'?{collectionQueryVersion:2,retainedHistoryVersion:1}:{}),agentProtocolVersion:8,agentProtocolVersions:env.NATIVE_RESEARCH_ENABLED==='true'?[8,9,10]:[8,9],nativeResearchEnabled:env.NATIVE_RESEARCH_ENABLED==='true'&&env.ALLOW_PUBLIC_LOOKUP==='true'&&env.ALLOW_RECONCILED_BUDGET==='true'&&env.LIVE_AI==='true'&&env.ENABLED==='true',agentToolsEnabled:env.ENABLED==='true'&&env.LIVE_AI==='true'&&env.ALLOW_RECONCILED_BUDGET==='true',publicBusinessToolsVersion:1,publicBusinessLookupEnabled:env.ENABLED==='true'&&env.LIVE_AI==='true'&&env.ALLOW_PUBLIC_LOOKUP==='true'&&env.ALLOW_RECONCILED_BUDGET==='true',selectedScreenshotEnabled:false,webDiscoveryEnabled:false,model:ACTIVE_MODEL,validationCapMicroUSD:VALIDATION_CAP_MICRO_USD});
  const token=request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_-]+)$/)?.[1],user=await ownerIdentity(token,env.OWNER_TOKEN_HASHES_JSON);
  if(!user)return json({error:'unauthorized'},401);
  if(env.ENABLED!=='true')return json({error:'disabled'},503);
  try{
   if(path==='/v1/status'&&request.method==='GET'){const r=await env.PRODUCTION.status(user);return json(r.body,r.status)}
   if(path!=='/v1/answer'||request.method!=='POST')return json({error:'not_found'},404);
   if(env.LIVE_AI!=='true')return json({error:'dispatch_disabled'},503);
   if(request.headers.get('Content-Type')?.split(';')[0]!=='application/json')return json({error:'invalid_request'},400);
   const reader=request.body?.getReader();if(!reader)return json({error:'invalid_request'},400);
   const protocol=request.headers.get('X-Feast-Agent-Protocol'),agent=['8','9','10','11'].includes(protocol),limit=protocol==='10'?DIRECT_NATIVE_LIMITS.maxRequestBytes:agent?512000:50000;
   const chunks=[];let size=0;while(true){const chunk=await reader.read();if(chunk.done)break;size+=chunk.value.byteLength;if(size>limit){await reader.cancel();return json({error:'request_limit'},413)}chunks.push(chunk.value)}
   const body=new Uint8Array(size);let offset=0;for(const chunk of chunks){body.set(chunk,offset);offset+=chunk.byteLength}
   const payload=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(body));
   if(protocol==='11'&&((payload?.mode==='researchPilot'&&env.RESEARCH_PILOT_ENABLED!=='true')||payload?.version!==11||!['researchPilot','researchPilotStatus','researchPilotStop'].includes(payload?.mode)))return json({error:'pilot_disabled'},503);
   if(protocol==='10'&&(env.NATIVE_RESEARCH_ENABLED!=='true'||env.ALLOW_PUBLIC_LOOKUP!=='true'||payload?.version!==10||payload?.mode!=='conversationStep'))return json({error:'native_research_disabled'},503);
   if(agent&&((['10','11'].includes(protocol)?false:protocol==='8'?(payload?.version!==8||payload?.mode!=='agentStep'):(payload?.version!==9||!['conversationStep','authorizeChange','webSearch','retryFence'].includes(payload?.mode)))||env.ALLOW_RECONCILED_BUDGET!=='true'))return json({error:'invalid_agent_request'},400);
   if((payload?.mode==='agentStep'||[9,10,11].includes(payload?.version))&&!agent)return json({error:'invalid_agent_request'},400);
   if(payload?.mode==='publicLookup'&&(env.ALLOW_PUBLIC_LOOKUP!=='true'||env.ALLOW_RECONCILED_BUDGET!=='true'))return json({error:'public_lookup_disabled'},503);
   const r=await env.PRODUCTION.answer(payload,user);return json(r.body,r.status);
  }catch{return json({error:'validation_unavailable'},503)}
 }
};
