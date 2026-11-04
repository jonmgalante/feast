// Individually approved devices only. No public sign-up, admin HTTP API, or collection data.
// Configuration contains invitation hashes, never invitation/runtime secrets.
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const HASH=/^[0-9a-f]{64}$/;
const TOKEN=/^[A-Za-z0-9_-]{43}$/;
const uuid=value=>typeof value==='string'&&UUID.test(value);
const hash=value=>typeof value==='string'&&HASH.test(value);
const token=value=>typeof value==='string'&&TOKEN.test(value);
const PREFIX='phone-access-v1:';
export const PHONE_OBJECT='phone-access-v1';
const json=(v,status=200)=>Response.json(v,{status,headers:{'Cache-Control':'no-store'}});
export async function phoneHash(purpose,value){
 if(!['invitation','device','identity'].includes(purpose)||typeof value!=='string')throw Error('invalid_access');
 const bytes=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(PREFIX+purpose+':'+value));
 return [...new Uint8Array(bytes)].map(x=>x.toString(16).padStart(2,'0')).join('');
}
export function phoneGrants(env){
 if(env.PHONE_ACCESS_ENABLED!=='true')return null;
 try{
  const raw=env.PHONE_INVITATIONS_JSON;if(typeof raw!=='string'||raw.length>32768)return null;
  const grants=JSON.parse(raw);if(!Array.isArray(grants)||!grants.length||grants.length>64)return null;
  const ids=new Set(),hashes=new Set();
  for(const g of grants){
   if(!g||Object.keys(g).sort().join(',')!=='createdAt,expiresAt,id,revoked,sha256'||!uuid(g.id)||!hash(g.sha256)||typeof g.revoked!=='boolean'||!Number.isSafeInteger(g.createdAt)||!Number.isSafeInteger(g.expiresAt)||g.createdAt<0||g.expiresAt<=g.createdAt||g.expiresAt-g.createdAt>30*86400000||ids.has(g.id)||hashes.has(g.sha256))return null;
   ids.add(g.id);hashes.add(g.sha256);
  }
  return grants;
 }catch{return null}
}
export async function accessJSON(request,limit){
 if(request.headers.get('Content-Type')?.split(';')[0]!=='application/json')throw Error('invalid_access');
 const reader=request.body?.getReader();if(!reader)throw Error('invalid_access');let size=0;const chunks=[];
 for(;;){const part=await reader.read();if(part.done)break;size+=part.value.length;if(size>limit){await reader.cancel();throw Error('invalid_access')}chunks.push(part.value)}
 const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length}
 return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
function checkedRecord(r){
 if(!r||r.version!==1||!uuid(r.grantID)||!uuid(r.deviceID)||!uuid(r.activationID)||!hash(r.credentialHash)||!hash(r.invitationHash)||!Number.isSafeInteger(r.activatedAt)||r.activatedAt<0)throw Error('access_unavailable');
 return r;
}
const receipt=r=>({version:1,grantID:r.grantID,deviceID:r.deviceID,activationID:r.activationID,activatedAt:r.activatedAt});
// Invoked only by the Worker through the existing private Durable Object binding.
// Use a separate object name; no access path touches the global accounting object.
export async function phoneAccessFetch(storage,request,env,now=Date.now()){
 const grants=phoneGrants(env);if(!grants)return json({error:'phone_access_disabled'},503);
 try{
  if(request.method!=='POST')return json({error:'not_found'},404);
  const path=new URL(request.url).pathname,p=await accessJSON(request,2048);
  if(path==='/phone-access/activate'){
   if(!p||Object.keys(p).sort().join(',')!=='activationID,credentialHash,deviceID,invitation,version'||p.version!==1||!uuid(p.deviceID)||!uuid(p.activationID)||!token(p.invitation)||!hash(p.credentialHash))return json({error:'invalid_activation'},400);
   const invitationHash=await phoneHash('invitation',p.invitation),grant=grants.find(g=>g.sha256===invitationHash);
   if(!grant||grant.revoked||grant.createdAt>now)return json({error:'invitation_unavailable'},403);
   return await storage.transaction(async tx=>{
    const previous=await tx.get(PREFIX+'grant:'+grant.id);
    if(previous){
     const r=checkedRecord(previous);
     if(r.grantID!==grant.id||r.invitationHash!==grant.sha256||r.deviceID!==p.deviceID||r.activationID!==p.activationID||r.credentialHash!==p.credentialHash)return json({error:'invitation_unavailable'},403);
     return json(receipt(r)); // Lost reply / relaunch: exact same activation, never a second device.
    }
    if(grant.expiresAt<=now)return json({error:'invitation_unavailable'},403);
    if(await tx.get(PREFIX+'credential:'+p.credentialHash)||await tx.get(PREFIX+'device:'+p.deviceID))return json({error:'activation_conflict'},409);
    const r={version:1,grantID:grant.id,deviceID:p.deviceID,activationID:p.activationID,invitationHash,credentialHash:p.credentialHash,activatedAt:now};
    await tx.put(PREFIX+'grant:'+grant.id,r);await tx.put(PREFIX+'credential:'+p.credentialHash,grant.id);await tx.put(PREFIX+'device:'+p.deviceID,grant.id);
    return json(receipt(r));
   });
  }
  if(path==='/phone-access/authenticate'){
   if(!p||Object.keys(p).join(',')!=='credentialHash'||!hash(p.credentialHash))return json({error:'unauthorized'},401);
   return await storage.transaction(async tx=>{
    const grantID=await tx.get(PREFIX+'credential:'+p.credentialHash),grant=grants.find(g=>g.id===grantID);
    if(!grant||grant.revoked||grant.createdAt>now)return json({error:'unauthorized'},401);
    const r=checkedRecord(await tx.get(PREFIX+'grant:'+grantID));
    if(r.grantID!==grant.id||r.credentialHash!==p.credentialHash||r.invitationHash!==grant.sha256)return json({error:'unauthorized'},401);
    return json({...receipt(r),userHash:await phoneHash('identity',r.grantID)});
   });
  }
  return json({error:'not_found'},404);
 }catch{return json({error:'access_unavailable'},503)}
}
export async function phoneAuthenticate(request,env){
 const token=request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1];
 if(!token)return null;
 const response=await phoneStore(env).fetch(new Request('https://access/phone-access/authenticate',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({credentialHash:await phoneHash('device',token)})}));
 if(response.status===401)return null;if(!response.ok)throw Error('access_unavailable');
 const result=await response.json();if(!hash(result.userHash))throw Error('access_unavailable');return result;
}
export function phoneStore(env){return env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName(PHONE_OBJECT))}
