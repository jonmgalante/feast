import {test,mock} from 'node:test';
import assert from 'node:assert/strict';
import {authenticate,digest,effectiveCredential,BudgetLedger} from './worker.mjs';
const TESTER_TWO_REPLACEMENT_HASH=effectiveCredential({id:'feast-dev-tester-two',expiresAt:'2026-11-22T14:30:00Z'},'dev').sha256;
const expiry='2026-11-22T14:30:00Z',one='a'.repeat(43),old='b'.repeat(43);
const request=t=>new Request('https://test.invalid',{headers:{Authorization:`Bearer ${t}`}});
async function records(){return [{id:'feast-dev-tester-one',sha256:await digest(one),expiresAt:expiry},{id:'feast-dev-tester-two',sha256:await digest(old),expiresAt:expiry}]}
test('effective replacement preserves input, identity and earlier expiry; capped and dev only',()=>{
 const r={id:'feast-dev-tester-two',sha256:'a'.repeat(64),expiresAt:'2026-11-01T00:00:00Z',extra:'retained'},before=structuredClone(r),v=effectiveCredential(r,'dev');
 assert.deepEqual(r,before);assert.equal(v.id,r.id);assert.equal(v.extra,r.extra);assert.equal(v.sha256,TESTER_TWO_REPLACEMENT_HASH);assert.equal(Date.parse(v.expiresAt),Date.parse(r.expiresAt));
 assert.equal(effectiveCredential({...r,expiresAt:'2027-01-01T00:00:00Z'},'dev').expiresAt,'2026-11-22T14:30:00.000Z');
 assert.equal(effectiveCredential({...r,expiresAt:'bad'},'dev'),null);assert.equal(effectiveCredential(r,'production'),r);
});
test('tester-one unchanged, old tester-two revoked, encrypted configuration immutable',async()=>{
 const users=await records(),config=JSON.stringify(users),env={ENVIRONMENT:'dev',CLIENT_TOKEN_HASHES_JSON:config};
 assert.equal(await authenticate(request(one),env),'feast-dev-tester-one');assert.equal(await authenticate(request(old),env),null);assert.equal(env.CLIENT_TOKEN_HASHES_JSON,config);
 assert.equal(await authenticate(request(old),{...env,ENVIRONMENT:'production'}),'feast-dev-tester-two');
});
test('replacement accepts only existing unique valid unexpired record; no new tester',async()=>{
 const users=await records();const hook=mock.method(crypto.subtle,'digest',async()=>Uint8Array.from(TESTER_TWO_REPLACEMENT_HASH.match(/../g),x=>parseInt(x,16)).buffer);
 try {
  const auth=rows=>authenticate(request('c'.repeat(43)),{ENVIRONMENT:'dev',CLIENT_TOKEN_HASHES_JSON:JSON.stringify(rows)});
  assert.equal(await auth(users),'feast-dev-tester-two');
  for(const rows of [[users[0],{...users[1],id:'different-tester'}],[users[1],users[1]],[users[0],{...users[1],expiresAt:'2020-01-01T00:00:00Z'}],[users[0],{...users[1],expiresAt:'bad'}],[users[0],{...users[1],sha256:'malformed'}]])assert.equal(await auth(rows),null);
 }finally{hook.mock.restore()}
});
test('same ledger identity preserves consumed cap across object recreation',async()=>{
 const data=new Map([['total',5000000],['user:feast-dev-tester-two',2500000]]),before=structuredClone([...data]);
 const storage={transaction:fn=>fn({get:async k=>data.get(k),put:async(k,v)=>data.set(k,v)})};
 const object=new BudgetLedger({storage});
 const r=await object.fetch(new Request('https://ledger/reserve',{method:'POST',body:JSON.stringify({user:'feast-dev-tester-two',id:crypto.randomUUID(),fingerprint:'a'.repeat(64)})}));
 assert.equal(r.status,429);assert.deepEqual([...data],before);
});
