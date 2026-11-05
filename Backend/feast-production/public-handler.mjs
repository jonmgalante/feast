import {ACTIVE_MODEL} from './active-model.mjs';
import {VALIDATION_CAP_MICRO_USD} from './budget-policy.mjs';
import {json,brokerAnswer} from './broker.mjs';
import {phoneGrants,phoneStore,phoneAuthenticate,phoneManage,accessJSON} from './phone-access.mjs';
import {validPublicRequest} from './public-business.mjs';
export async function publicFetch(request,env,send=fetch){
  const path=new URL(request.url).pathname;
  const enabled=phoneGrants(env)!==null,live=enabled&&env.ENVIRONMENT==='production'&&env.OWNER_VALIDATION_ENABLED==='true'&&env.LIVE_AI==='true'&&env.ALLOW_RECONCILED_BUDGET==='true';
  if(request.method==='GET'&&path==='/health')return json({service:'feast-production',environment:'production',requestsEnabled:live,enrollmentEnabled:enabled,ownerValidationEnabled:env?.OWNER_VALIDATION_ENABLED==='true',validationCapMicroUSD:VALIDATION_CAP_MICRO_USD,model:ACTIVE_MODEL,reasoning:'medium',...(enabled?{savedMetadataEnabled:true,savedToolsEnabled:live,savedToolsVersion:3,agentProtocolVersion:8,agentProtocolVersions:env.NATIVE_RESEARCH_ENABLED==='true'?[8,9,10]:[8,9],agentToolsEnabled:live,publicBusinessToolsVersion:1,publicBusinessLookupEnabled:live&&env.ALLOW_PUBLIC_LOOKUP==='true',nativeResearchEnabled:live&&env.NATIVE_RESEARCH_ENABLED==='true'&&env.ALLOW_PUBLIC_LOOKUP==='true',selectedScreenshotEnabled:false,webDiscoveryEnabled:false}:{})});
  if(!enabled)return json({error:'public_enrollment_not_activated'},503);
  try{
   if(path==='/v1/access/activate'&&request.method==='POST'){
    const payload=await accessJSON(request,2048);
    return await phoneStore(env).fetch(new Request('https://access/phone-access/activate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}));
   }
   if(path==='/v1/access/manage'&&request.method==='POST')return await phoneManage(request,env);
   if(!((path==='/v1/access/status'&&request.method==='GET')||(path==='/v1/answer'&&request.method==='POST')))return json({error:'not_found'},404);
   const actor=await phoneAuthenticate(request,env);if(!actor)return json({error:'unauthorized'},401);
   if(path==='/v1/access/status'){const {userHash,...status}=actor;return json(status)}
   if(!live)return json({error:'dispatch_disabled'},503);
   const protocol=request.headers.get('X-Feast-Agent-Protocol'),p=await accessJSON(request,protocol===null?4096:512000);
   // The existing native-off rollback uses this public-only, headerless v7 request.
   // Do not enable the older general library protocols or accept private context here.
   const legacyLookup=protocol===null&&typeof p?.requestID==='string'&&validPublicRequest(p);
   // Ordinary clients cannot reach the owner-only pilot, diagnostics, or global ledger status.
   if(!legacyLookup&&(!['8','9','10'].includes(protocol)||p?.version!==Number(protocol)||!(protocol==='8'?p.mode==='agentStep':protocol==='9'?['conversationStep','authorizeChange','webSearch','retryFence'].includes(p.mode):p.mode==='conversationStep')))return json({error:'invalid_agent_request'},400);
   if(protocol==='10'&&(env.NATIVE_RESEARCH_ENABLED!=='true'||env.ALLOW_PUBLIC_LOOKUP!=='true'))return json({error:'native_research_disabled'},503);
   const response=await brokerAnswer(p,actor.userHash,env,send);
   // Accounting remains authoritative server-side; do not disclose the sponsor's
   // global usage or other devices' holds to invited clients.
   const body=await response.json();delete body.budget;
   return json(body,response.status);
  }catch{return json({error:'access_unavailable'},503)}
}
export default {fetch(request,env){return publicFetch(request,env)}};
