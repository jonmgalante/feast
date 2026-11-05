import test from 'node:test';import assert from 'node:assert/strict';
import {publicFetch} from './public-handler.mjs';import {phoneAccessFetch,phoneHash} from './phone-access.mjs';
const id=n=>`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`,secret=c=>c.repeat(43),now=1000000;
function storage(){const data=new Map();let q=Promise.resolve();return {data,transaction(fn){const job=q.then(async()=>{const next=structuredClone(data);const result=await fn({get:async k=>next.get(k),put:async(k,v)=>next.set(k,structuredClone(v)),list:async({prefix})=>new Map([...next].filter(([k])=>k.startsWith(prefix)))});data.clear();for(const pair of next)data.set(...pair);return result});q=job.catch(()=>{});return job}}}
const req=(path,p,token)=>new Request('https://test'+path,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(p)});
async function setup(){const s=storage(),owner={id:id(1),sha256:await phoneHash('invitation',secret('i')),createdAt:0,expiresAt:now+100,revoked:false};const env={PHONE_ACCESS_ENABLED:'true',PHONE_INVITATIONS_JSON:JSON.stringify([owner]),PHONE_OWNER_GRANT_ID:owner.id};
 const call=(path,p,t=now)=>phoneAccessFetch(s,req('/phone-access/'+path,p),env,t);
 const activation={version:1,invitation:secret('i'),credentialHash:await phoneHash('device',secret('o')),deviceID:id(2),activationID:id(3)};
 await call('activate',activation);
 const manage=command=>call('manage',{credentialHash:activation.credentialHash,command});
 const invitation=async(n=10,c='j')=>({kind:'invite',id:id(n),label:'Juliet’s phone',sha256:await phoneHash('invitation',secret(c))});
 env.PRODUCTION_STATE={idFromName:n=>n,get:()=>({fetch:r=>phoneAccessFetch(s,r,env,now)})};
 return {s,env,owner,call,manage,invitation,activation};}
test('owner authority is static, optional and never inferred from body or label',async()=>{
 const {manage,env,call,activation}=await setup();assert.equal((await manage({kind:'list'})).status,200);
 for(const value of [undefined,'garbage',id(99)]){env.PHONE_OWNER_GRANT_ID=value;assert.equal((await manage({kind:'list'})).status,403);assert.equal((await call('authenticate',{credentialHash:activation.credentialHash})).status,200)}
});
test('creation exact replay, conflicting replay, concurrency and safe list projection',async()=>{
 const {manage,invitation,s}=await setup(),c=await invitation();const replies=await Promise.all([manage(c),manage(c)]);assert(replies.every(r=>r.status===200));assert.deepEqual(await replies[0].json(),await replies[1].json());
 assert.equal(s.data.get('phone-access-v1:managed').length,1);assert.equal((await manage({...c,label:'Different'})).status,409);
 const list=await(await manage({kind:'list'})).json();assert.equal(list.entries.length,2);assert(!JSON.stringify(list).includes(c.sha256));assert(!JSON.stringify([...s.data]).includes(secret('j')));
});
test('members cannot create, list, revoke, spoof actor or assign owner role',async()=>{
 const {manage,invitation,call,env}=await setup(),c=await invitation();await manage(c);
 const p={version:1,invitation:secret('j'),credentialHash:await phoneHash('device',secret('m')),deviceID:id(20),activationID:id(21)};assert.equal((await call('activate',p)).status,200);
 for(const command of [{kind:'list'},await invitation(11,'k'),{kind:'revoke',id:id(1)}])assert.equal((await call('manage',{credentialHash:p.credentialHash,command})).status,403);
 const attack=await publicFetch(req('/v1/access/manage',{kind:'list',credentialHash:await phoneHash('device',secret('o'))},secret('m')),env);assert.equal(attack.status,403);
 assert.equal((await manage({...await invitation(12,'l'),role:'owner'})).status,400);
});
test('revocation blocks redemption and active authentication, retries never resurrect',async()=>{
 const {manage,invitation,call}=await setup(),c=await invitation();await manage(c);
 const p={version:1,invitation:secret('j'),credentialHash:await phoneHash('device',secret('m')),deviceID:id(20),activationID:id(21)};
 await call('activate',p);assert.equal((await manage({kind:'revoke',id:c.id})).status,200);assert.equal((await manage({kind:'revoke',id:c.id})).status,200);
 assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,401);assert.equal((await call('activate',p)).status,403);
 assert.equal((await(await manage(c)).json()).entry.state,'revoked');assert.equal((await manage({kind:'revoke',id:id(1)})).status,403);
});
test('revocation and redemption serialize with no surviving access',async()=>{
 const {manage,invitation,call}=await setup(),c=await invitation();await manage(c);const p={version:1,invitation:secret('j'),credentialHash:await phoneHash('device',secret('m')),deviceID:id(20),activationID:id(21)};
 const result=await Promise.all([call('activate',p),manage({kind:'revoke',id:c.id})]);assert([200,403].includes(result[0].status));assert.equal(result[1].status,200);assert.equal((await call('authenticate',{credentialHash:p.credentialHash})).status,401);
});
test('owner recovery retires old authority while members, holds and records survive',async()=>{
 const {s,env,owner,manage,invitation,call,activation}=await setup(),c=await invitation();await manage(c);const member={version:1,invitation:secret('j'),credentialHash:await phoneHash('device',secret('m')),deviceID:id(20),activationID:id(21)};await call('activate',member);
 s.data.set('unrelated-hold',{amount:6800288,state:'unknown'});const next={...owner,id:id(30),sha256:await phoneHash('invitation',secret('n'))};env.PHONE_INVITATIONS_JSON=JSON.stringify([{...owner,revoked:true},next]);env.PHONE_OWNER_GRANT_ID=next.id;
 assert.equal((await manage({kind:'list'})).status,401);assert.equal((await call('authenticate',{credentialHash:member.credentialHash})).status,200);
 const replacement={...activation,invitation:secret('n'),credentialHash:await phoneHash('device',secret('p')),deviceID:id(31),activationID:id(32)};await call('activate',replacement);
 assert.equal((await call('manage',{credentialHash:replacement.credentialHash,command:{kind:'list'}})).status,200);assert.deepEqual(s.data.get('unrelated-hold'),{amount:6800288,state:'unknown'});
 assert.equal((await call('manage',{credentialHash:replacement.credentialHash,command:c})).status,409);
});
test('static and historical invitation collisions, malformed input and capacity fail closed',async()=>{
 const {s,manage,invitation,owner,env}=await setup(),c=await invitation();assert.equal((await manage({...c,id:owner.id})).status,409);assert.equal((await manage({...c,sha256:owner.sha256})).status,409);
 for(const bad of [{...c,label:''},{...c,label:'\nowner'},{...c,id:'bad'},{...c,sha256:'bad'},null])assert.equal((await manage(bad)).status,400);
 await manage(c);assert.equal((await manage(await invitation(11))).status,409);
 s.data.set('phone-access-v1:managed',[{...s.data.get('phone-access-v1:managed')[0],expiresAt:'bad'}]);assert.equal((await manage({kind:'list'})).status,503);
});
test('expiry ends unclaimed invitations but not already activated member access',async()=>{
 const {manage,invitation,call}=await setup();const c=await invitation();const g=(await(await manage(c)).json()).entry;assert.equal(g.expiresAt,now+86400000);
 const p={version:1,invitation:secret('j'),credentialHash:await phoneHash('device',secret('m')),deviceID:id(20),activationID:id(21)};
 assert.equal((await call('activate',p,g.expiresAt)).status,403);assert.equal((await call('activate',p)).status,200);assert.equal((await call('authenticate',{credentialHash:p.credentialHash},g.expiresAt+1)).status,200);
});
test('bounded invitation directory refuses additional creation without dropping history',async()=>{
 const {s,manage,invitation}=await setup();
 const managed=[];for(let n=100;n<356;n++)managed.push({id:id(n),sha256:n.toString(16).padStart(64,'0'),label:'Offline member',createdBy:id(1),createdAt:now,expiresAt:now+86400000,revoked:false});
 s.data.set('phone-access-v1:managed',managed);const before=structuredClone(s.data);
 assert.equal((await manage(await invitation())).status,409);assert.deepEqual(s.data,before);
});
