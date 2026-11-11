// Read compatibility only. New native/staged/managed admission remains UUID-only.
// These are the exact original direct-ledger ID domains, not a new ID grammar.
import {jobHash,jobUUID} from './answer-job-contract.mjs';
import {PUBLIC_PROFILES} from './public-policy.mjs';
const V1='production-validation-v1:request:',V2='production-validation-v2:request:';
const links=['executionVersion','rootRequestID','nativeTurnID','stageIndex'];
const directProfiles=new Set(['saved','public',...Object.keys(PUBLIC_PROFILES)]);
export const historicalRootID=value=>typeof value==='string'&&/^[a-z0-9-]{36}$/i.test(value);
export function historicalRequestID(key,record){
 const version=key.startsWith(V1)?1:key.startsWith(V2)?2:0;if(!version)return false;
 const id=key.slice((version===1?V1:V2).length);if(jobUUID(id))return true;
 if(!record||typeof record!=='object'||Array.isArray(record)||!jobHash(record.userHash)||!jobHash(record.fingerprint)||links.some(k=>Object.hasOwn(record,k)))return false;
 // Missing linkage cannot turn a staged/native profile into an old direct row.
 if(version===1?Object.hasOwn(record,'profile'):!directProfiles.has(record.profile))return false;
 return typeof id==='string'&&(version===1?/^[a-z0-9-]{36}$/i:/^[a-f0-9-]{36}$/i).test(id);
}
// Ownership alone intentionally groups case aliases, as the full historical
// scan does. Exact physical-key record proofs/billing remain separate. Keeping
// all 36 ASCII characters makes distinct hyphen positions collision-free.
export function accountingOwnerPath(root){
 if(!historicalRootID(root))throw Error('accounting_index_root_identity');
 return [...root.toLowerCase()].map(c=>c.charCodeAt(0).toString(16).padStart(2,'0')).join('');
}
