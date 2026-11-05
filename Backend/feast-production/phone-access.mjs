// Individually approved devices. Owner authority comes only from Cloudflare configuration.
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
const MANAGED=PREFIX+'managed';
const revokedKey=id=>PREFIX+'revoked:'+id;
const ownerID=env=>uuid(env.PHONE_OWNER_GRANT_ID)?env.PHONE_OWNER_GRANT_ID:null;
const label=v=>typeof v==='string'&&v.trim()===v&&v.length>=1&&v.length<=80&&!/[\u0000-\u001f\u007f]/.test(v);
async function allGrants(tx,configured){
 const managed=await tx.get(MANAGED)??[];
 if(!Array.isArray(managed)||managed.length>256)throw Error('access_unavailable');
 for(const g of managed)if(!g||Object.keys(g).sort().join(',')!=='createdAt,createdBy,expiresAt,id,label,revoked,sha256'||!uuid(g.createdBy)||!label(g.label)||g.revoked!==false||!Number.isSafeInteger(g.createdAt)||g.createdAt<0||!Number.isSafeInteger(g.expiresAt)||g.expiresAt-g.createdAt!==86400000)throw Error('access_unavailable');
 const all=[...configured,...managed],ids=new Set(),hashes=new Set();
 for(const g of all){
  if(!uuid(g.id)||!hash(g.sha256)||ids.has(g.id)||hashes.has(g.sha256))throw Error('access_unavailable');
  ids.add(g.id);hashes.add(g.sha256);
 }
 return all;
}
async function authenticated(tx,grants,credentialHash,now){
 const grantID=await tx.get(PREFIX+'credential:'+credentialHash),grant=grants.find(g=>g.id===grantID);
 if(!grant||grant.revoked||grant.createdAt>now||await tx.get(revokedKey(grant.id)))return null;
 const r=checkedRecord(await tx.get(PREFIX+'grant:'+grantID));
 if(r.grantID!==grant.id||r.credentialHash!==credentialHash||r.invitationHash!==grant.sha256)return null;
 return r;
}
async function entry(tx,g,env,now){
 const r=await tx.get(PREFIX+'grant:'+g.id),revoked=g.revoked||!!await tx.get(revokedKey(g.id));
 return {id:g.id,label:g.label??(g.id===ownerID(env)?'Owner':'Invited device'),role:g.id===ownerID(env)?'owner':'member',
  state:revoked?'revoked':r?'active':g.expiresAt<=now?'expired':'invited',createdAt:g.createdAt,expiresAt:g.expiresAt,activatedAt:r?checkedRecord(r).activatedAt:null};
}
// Invoked only through the private Durable Object binding. Management reauthenticates
// inside the same transaction as every read/write; HTTP cannot supply an actor hash.
export async function phoneAccessFetch(storage,request,env,now=Date.now()){
 const configured=phoneGrants(env);if(!configured)return json({error:'phone_access_disabled'},503);
 try{
  if(request.method!=='POST')return json({error:'not_found'},404);
  const path=new URL(request.url).pathname,p=await accessJSON(request,2048);
  if(path==='/phone-access/activate'){
   if(!p||Object.keys(p).sort().join(',')!=='activationID,credentialHash,deviceID,invitation,version'||p.version!==1||!uuid(p.deviceID)||!uuid(p.activationID)||!token(p.invitation)||!hash(p.credentialHash))return json({error:'invalid_activation'},400);
   const invitationHash=await phoneHash('invitation',p.invitation);
   return await storage.transaction(async tx=>{
    const grants=await allGrants(tx,configured),grant=grants.find(g=>g.sha256===invitationHash);
    if(!grant||grant.revoked||grant.createdAt>now||await tx.get(revokedKey(grant.id)))return json({error:'invitation_unavailable'},403);
    const previous=await tx.get(PREFIX+'grant:'+grant.id);
    if(previous){
     const r=checkedRecord(previous);
     if(r.grantID!==grant.id||r.invitationHash!==grant.sha256||r.deviceID!==p.deviceID||r.activationID!==p.activationID||r.credentialHash!==p.credentialHash)return json({error:'invitation_unavailable'},403);
     return json(receipt(r));
    }
    const priorInvitation=await tx.get(PREFIX+'invitation:'+invitationHash);
    if(priorInvitation&&priorInvitation!==grant.id)return json({error:'invitation_unavailable'},403);
    if(grant.expiresAt<=now)return json({error:'invitation_unavailable'},403);
    if(await tx.get(PREFIX+'credential:'+p.credentialHash)||await tx.get(PREFIX+'device:'+p.deviceID))return json({error:'activation_conflict'},409);
    const r={version:1,grantID:grant.id,deviceID:p.deviceID,activationID:p.activationID,invitationHash,credentialHash:p.credentialHash,activatedAt:now};
    await tx.put(PREFIX+'invitation:'+invitationHash,grant.id);await tx.put(PREFIX+'grant:'+grant.id,r);await tx.put(PREFIX+'credential:'+p.credentialHash,grant.id);await tx.put(PREFIX+'device:'+p.deviceID,grant.id);
    return json(receipt(r));
   });
  }
  if(path==='/phone-access/authenticate'){
   if(!p||Object.keys(p).join(',')!=='credentialHash'||!hash(p.credentialHash))return json({error:'unauthorized'},401);
   return await storage.transaction(async tx=>{
    const r=await authenticated(tx,await allGrants(tx,configured),p.credentialHash,now);
    if(!r)return json({error:'unauthorized'},401);
    return json({...receipt(r),role:configured.some(g=>g.id===r.grantID)&&r.grantID===ownerID(env)?'owner':'member',userHash:await phoneHash('identity',r.grantID)});
   });
  }
  if(path==='/phone-access/manage'){
   if(!p||Object.keys(p).sort().join(',')!=='command,credentialHash'||!hash(p.credentialHash)||!p.command)return json({error:'invalid_management'},400);
   return await storage.transaction(async tx=>{
    const grants=await allGrants(tx,configured),actor=await authenticated(tx,grants,p.credentialHash,now);
    if(!actor)return json({error:'unauthorized'},401);
    if(actor.grantID!==ownerID(env)||!configured.some(g=>g.id===actor.grantID))return json({error:'owner_required'},403);
    const c=p.command,keys=Object.keys(c).sort().join(',');
    if(keys==='kind'&&c.kind==='list')return json({version:1,entries:await Promise.all(grants.map(g=>entry(tx,g,env,now)))});
    if(keys==='id,kind,label,sha256'&&c.kind==='invite'&&uuid(c.id)&&hash(c.sha256)&&label(c.label)){
     const existing=grants.find(g=>g.id===c.id);
     if(existing){
      if(existing.createdBy!==actor.grantID||existing.label!==c.label||existing.sha256!==c.sha256)return json({error:'operation_conflict'},409);
      return json({version:1,entry:await entry(tx,existing,env,now)});
     }
     // Historical activation keys are tombstones even if admin removed a static grant.
     if(c.id===ownerID(env)||grants.some(g=>g.sha256===c.sha256)||await tx.get(PREFIX+'grant:'+c.id)||await tx.get(PREFIX+'invitation:'+c.sha256))return json({error:'operation_conflict'},409);
     const historical=await tx.list({prefix:PREFIX+'grant:',limit:1025});
     if(historical.size>1024)return json({error:'access_capacity'},409);
     if([...historical.values()].some(r=>checkedRecord(r).invitationHash===c.sha256))return json({error:'operation_conflict'},409);
     const managed=await tx.get(MANAGED)??[];
     if(managed.length>=256)return json({error:'access_capacity'},409);
     const g={id:c.id,sha256:c.sha256,label:c.label,createdBy:actor.grantID,createdAt:now,expiresAt:now+86400000,revoked:false};
     await tx.put(MANAGED,[...managed,g]);await tx.put(PREFIX+'invitation:'+c.sha256,c.id);
     return json({version:1,entry:await entry(tx,g,env,now)});
    }
    if(keys==='id,kind'&&c.kind==='revoke'&&uuid(c.id)){
     const g=grants.find(g=>g.id===c.id);
     if(!g)return json({error:'access_not_found'},404);
     if(g.id===ownerID(env))return json({error:'owner_recovery_required'},403);
     if(!await tx.get(revokedKey(g.id)))await tx.put(revokedKey(g.id),{at:now,by:actor.grantID});
     return json({version:1,entry:await entry(tx,g,env,now)});
    }
    return json({error:'invalid_management'},400);
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
export async function phoneManage(request,env){
 const credential=request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1];
 if(!credential)return json({error:'unauthorized'},401);
 const command=await accessJSON(request,1024);
 return phoneStore(env).fetch(new Request('https://access/phone-access/manage',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({credentialHash:await phoneHash('device',credential),command})}));
}
export function phoneStore(env){return env.PRODUCTION_STATE.get(env.PRODUCTION_STATE.idFromName(PHONE_OBJECT))}
