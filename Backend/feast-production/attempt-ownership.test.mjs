import test from 'node:test';import assert from 'node:assert/strict';
import {attemptOwnershipBatch} from './attempt-ownership.mjs';

test('batch ownership scans all pages once and detects a late mixed-case alias without changing records',async()=>{
 const root='abcdefab-cdef-abcd-efab-cdefabcdefab',userHash='a'.repeat(64),prefix='production-validation-v2:request:',data=new Map();
 for(let i=0;i<2000;i++)data.set(prefix+String(i).padStart(8,'0'),{userHash});
 data.set(prefix+'zz-last',{userHash:'b'.repeat(64),rootRequestID:root.slice(0,10).toUpperCase()+root.slice(10)});
 let scans=0;const tx={list:async({prefix,limit,startAfter})=>{scans++;return new Map([...data].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a<b?-1:1).slice(0,limit))}};
 const roots=[root,...Array.from({length:63},()=>crypto.randomUUID())],before=structuredClone(data),owners=await attemptOwnershipBatch(tx,roots,userHash);
 assert.equal(owners.get(root).owned,false);assert(roots.slice(1).every(x=>owners.get(x).owned));assert.equal(scans,7);assert.deepEqual(data,before);
});
