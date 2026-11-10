// Cross-protocol root ownership is shared by retry fencing and Stop. Read every
// case alias, not just the first existing key: old writers preserved UUID case.
// Call inside the transaction that installs the close fence. Ownership alone
// does not authorize settling a pending/uncertain accounting hold.
export async function attemptOwnership(tx,root,userHash){return (await attemptOwnershipBatch(tx,[root],userHash)).get(root.toLowerCase())}
export async function attemptOwnershipBatch(tx,roots,userHash){
 const result=new Map(roots.map(root=>[root.toLowerCase(),{owned:true,accounting:[]}]));
 for(const prefix of ['production-validation-v2:native-root:','production-validation-v2:stage-root:','production-validation-v2:closed-root:','production-validation-v2:request:','production-validation-v1:request:']){
  let startAfter;
  for(;;){
   const page=await tx.list({prefix,limit:1000,...(startAfter?{startAfter}:{})});
   if(!(page instanceof Map))throw Error('accounting_incomplete');
   if(!page.size)break;
   const last=[...page.keys()].at(-1);if(startAfter&&last<=startAfter)throw Error('accounting_incomplete');
   for(const [key,record] of page){
    if(!record||typeof record!=='object'||Array.isArray(record)||record.rootRequestID!=null&&typeof record.rootRequestID!=='string')throw Error('accounting_corrupt');
    const matching=new Set([key.slice(prefix.length).toLowerCase(),record?.rootRequestID?.toLowerCase()]);
    for(const root of matching){
     const ownership=result.get(root);if(!ownership)continue;
     if(!record||record.userHash!==userHash)ownership.owned=false;
     if(prefix.endsWith('request:'))ownership.accounting.push(record);
    }
   }
   if(page.size<1000)break;startAfter=last;
  }
 }
 return result;
}
