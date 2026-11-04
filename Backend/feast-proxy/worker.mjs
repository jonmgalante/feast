import {validLibraryIntent,libraryIntentBody,callLibraryIntent} from './library-intent.mjs';
import {EVALUATION_RUN,EVALUATION_TESTER,EVALUATION_MAX,EVALUATION_CASES,evaluationCase,verifiedEvaluationStatus,compareEvaluation} from './evaluation.mjs';
import {localExtractionCandidate} from './discovery-local-candidate.mjs';
import { validDiscovery, callDiscovery, WEB_RESERVATION } from './discovery.mjs';
import { callOpenAI, providerBody, MODEL, RESERVATION, TOTAL_CAP, USER_CAP } from './openai.mjs';
// Live dispatch requires explicit dev activation, authentication and a permanent budget reservation.
const json = (body, status = 200, extra = {}) => Response.json(body, { status, headers: { 'Cache-Control': 'no-store', ...extra } });
export async function digest(value) {
  return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))), x => x.toString(16).padStart(2, '0')).join('');
}
// Approved dev-only replacement. The encrypted allowlist and ledger identity stay intact.
const TESTER_TWO_REPLACEMENT_HASH = '1a80e41d806c733f61d2bf9059b2591c3a9b18bb2500beed114bd475b38c094c';
export function effectiveCredential(record, environment) {
  if (environment !== 'dev' || record.id !== 'feast-dev-tester-two') return record;
  if (typeof record.expiresAt !== 'string') return null;
  const configuredExpiry = Date.parse(record.expiresAt);
  if (!Number.isFinite(configuredExpiry)) return null;
  return {...record, sha256: TESTER_TWO_REPLACEMENT_HASH,
    expiresAt: new Date(Math.min(configuredExpiry, Date.parse('2026-11-22T14:30:00Z'))).toISOString()};
}
export async function authenticate(request, env) {
  let users;
  try { users = JSON.parse(env.CLIENT_TOKEN_HASHES_JSON); } catch { return null; }
  if (!Array.isArray(users) || users.length !== 2 || users.some(x => !x || typeof x !== 'object') || new Set(users.map(x => x.id)).size !== 2 ||
      new Set(users.map(x => x.sha256)).size !== 2 || users.some(x => !x || !/^[a-z0-9-]{1,40}$/.test(x.id) || !/^[a-f0-9]{64}$/.test(x.sha256))) return null;
  const token = request.headers.get('Authorization')?.match(/^Bearer ([A-Za-z0-9_-]{43,128})$/)?.[1];
  if (!token) return null;
  const hash = await digest(token);
  const effective = users.map(x => effectiveCredential(x, env.ENVIRONMENT));
  // Never let a replacement collide with another existing identity.
  const hashes = effective.filter(Boolean).map(x => x.sha256);
  if (new Set(hashes).size !== hashes.length) return null;
  return effective.find(x => x && x.sha256 === hash && Number.isFinite(Date.parse(x.expiresAt)) && Date.parse(x.expiresAt) > Date.now())?.id ?? null;
}
export async function boundedJSON(request) {
  if (!request.headers.get('Content-Type')?.startsWith('application/json')) throw Error('type');
  const reader = request.body?.getReader();
  if (!reader) throw Error('body');
  let length = 0; const chunks = [];
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    length += value.byteLength;
    if (length > 300000) { await reader.cancel(); throw Error('size'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
}
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const text = (value, limit) => typeof value === 'string' && value.length > 0 && value.length <= limit;
const fields = (value, names) => value && typeof value === 'object' && !Array.isArray(value) &&
  Object.keys(value).length === names.length && names.every(name => Object.hasOwn(value, name));
function boundedJPEG(bytes){
  if(bytes.length<4||bytes.charCodeAt(0)!==255||bytes.charCodeAt(1)!==216||bytes.charCodeAt(bytes.length-2)!==255||bytes.charCodeAt(bytes.length-1)!==217)return false;
  let offset=2,dimensions=false;
  while(offset+3<bytes.length){
    if(bytes.charCodeAt(offset)!==255)return false;
    const marker=bytes.charCodeAt(offset+1);
    if(marker===218)return dimensions;
    const length=(bytes.charCodeAt(offset+2)<<8)|bytes.charCodeAt(offset+3);
    if(length<2||offset+length+2>bytes.length)return false;
    if([192,193,194].includes(marker)){
      if(length<8)return false;
      const h=(bytes.charCodeAt(offset+5)<<8)|bytes.charCodeAt(offset+6),w=(bytes.charCodeAt(offset+7)<<8)|bytes.charCodeAt(offset+8);
      if(w<1||h<1||w>1024||h>1024)return false;dimensions=true;
    }
    offset+=length+2;
  }
  return false;
}
function validSavedPayload(p) {
  const names=['version','synthetic','consent','requestID','mode','text','candidates','sources'];
  if(p?.attachment!==undefined)names.push('attachment');
  if(!fields(p,names)||p.version!==2||p.synthetic!==false||p.consent!==true||!uuid.test(p.requestID)||p.mode!=='collection'||!text(p.text,4000)||!Array.isArray(p.candidates)||p.candidates.length>6||!Array.isArray(p.sources)||p.sources.length>7)return false;
  if(p.attachment!==undefined){
    const a=p.attachment;
    if(!fields(a,['mime','base64','selected'])||a.mime!=='image/jpeg'||a.selected!==true||typeof a.base64!=='string'||a.base64.length>262144||!/^[A-Za-z0-9+/]+={0,2}$/.test(a.base64))return false;
    try{const bytes=atob(a.base64);if(bytes.length>196608||!boundedJPEG(bytes))return false;}catch{return false;}
  }
  if(new Set(p.candidates.map(x=>x?.id)).size!==p.candidates.length||new Set(p.sources.map(x=>x?.id)).size!==p.sources.length)return false;
  const needed=new Set();
  for(const c of p.candidates){
    if(!fields(c,['id','name','sourceIDs'])||!uuid.test(c.id)||!text(c.name,200)||!Array.isArray(c.sourceIDs)||c.sourceIDs.length!==1||c.sourceIDs[0]!=='metadata-'+c.id)return false;
    needed.add(c.sourceIDs[0]);
    const source=p.sources.find(x=>x?.id===c.sourceIDs[0]);
    if(!fields(source,['id','author','excerpt'])||source.author!=='Saved place metadata'||typeof source.excerpt!=='string'||source.excerpt.length>1500)return false;
    let m;try{m=JSON.parse(source.excerpt);}catch{return false;}
    if(!m||typeof m!=='object'||Array.isArray(m)||m.name!==c.name||Object.keys(m).some(key=>!['name','cuisines','address','rating'].includes(key)))return false;
    if(m.cuisines!==undefined&& !text(m.cuisines,500))return false;
    if(m.address!==undefined&& !text(m.address,400))return false;
    if(m.rating!==undefined&& (typeof m.rating!=='number'||!Number.isFinite(m.rating)||m.rating<0||m.rating>5))return false;
  }
  if(p.attachment){
    needed.add('selected-screenshot');const image=p.sources.find(x=>x?.id==='selected-screenshot');
    if(!fields(image,['id','author','excerpt'])||image.author!=='Selected screenshot'||image.excerpt!=='Image deliberately attached to this question.')return false;
  }
  return p.sources.length===needed.size&&p.sources.every(s=>needed.has(s.id));
}
export function validPayload(p) {
  if ([4,5,6].includes(p?.version)) return validLibraryIntent(p);
  if(p?.version===3)return validDiscovery(p);
  if(p?.version===2)return validSavedPayload(p);
  if (!fields(p, ['version','synthetic','consent','requestID','mode','text','candidates','sources']) ||
      p.version !== 1 || p.synthetic !== true || p.consent !== true || !uuid.test(p.requestID) ||
      !['collection','importText'].includes(p.mode) || !text(p.text,4000) ||
      !Array.isArray(p.candidates) || p.candidates.length > 6 || !Array.isArray(p.sources) || p.sources.length > 12) return false;
  if (!p.sources.every(x => fields(x,['id','author','excerpt']) && text(x.id,120) && text(x.author,120) &&
      typeof x.excerpt === 'string' && x.excerpt.length <= 1500)) return false;
  const sourceIDs = new Set(p.sources.map(x => x.id));
  return sourceIDs.size === p.sources.length &&
    p.candidates.every(x => fields(x,['id','name','sourceIDs']) && text(x.id,120) && text(x.name,200) &&
      Array.isArray(x.sourceIDs) && x.sourceIDs.length > 0 && x.sourceIDs.length <= 12 &&
      new Set(x.sourceIDs).size === x.sourceIDs.length && x.sourceIDs.every(id => sourceIDs.has(id))) &&
    new Set(p.candidates.map(x => x.id)).size === p.candidates.length;
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path === '/health' && request.method === 'GET') return json({ service:'feast-proxy', revision:'step2-disabled-v1', liveAI:env.LIVE_AI === 'true', requestsEnabled:env.ENABLED === 'true', environment:env.ENVIRONMENT, model:MODEL, totalCapMicroUSD:TOTAL_CAP, savedMetadataEnabled:env.ALLOW_SAVED_METADATA === 'true', selectedScreenshotEnabled:env.ALLOW_SELECTED_SCREENSHOT === 'true', webDiscoveryEnabled:env.ALLOW_DISCOVERY === 'true', savedToolsEnabled:env.ENVIRONMENT === 'dev' && env.ALLOW_LIBRARY_TOOLS === 'true', savedToolsVersion:env.ALLOW_LIBRARY_CONTEXT === 'true' ? 3 : 2, evaluationEnabled:env.ENVIRONMENT === 'dev' && env.ALLOW_DISCOVERY_EVALUATION === 'true' });
    const evaluationStatus = path === '/v1/evaluation/status' && request.method === 'GET';
    const evaluationRequest = path === '/v1/evaluation/answer' && request.method === 'POST';
    if (!evaluationStatus && !evaluationRequest && (path !== '/v1/answer' || request.method !== 'POST')) return json({ error: 'not_found' }, 404);
    const user = await authenticate(request, env);
    if (!user) return json({ error: 'unauthorized' }, 401);
    if (env.ENABLED !== 'true') return json({ error: 'disabled' }, 503);
    if (evaluationStatus || evaluationRequest) {
      if (env.ENVIRONMENT !== 'dev' || env.ALLOW_DISCOVERY_EVALUATION !== 'true') return json({error:'evaluation_disabled'},503);
      if (user !== EVALUATION_TESTER) return json({error:'evaluation_tester_not_allowed'},403);
      if (evaluationStatus) {
        try {
          const ledger=env.BUDGET.get(env.BUDGET.idFromName('shared-lifetime-v1'));
          const result=await ledger.fetch(new Request('https://ledger/evaluation-status',{method:'POST',body:JSON.stringify({user})}));
          if(!result.ok)return json({error:'evaluation_budget_unverified'},503);
          const status=await result.json();
          return verifiedEvaluationStatus(status)?json(status):json({error:'evaluation_budget_unverified'},503);
        }catch{return json({error:'evaluation_budget_unverified'},503)}
      }
    }
    let payload;
    try { payload = await boundedJSON(request); } catch { return json({ error: 'invalid_request' }, 400); }
    if (!validPayload(payload)) return json({ error: 'invalid_request' }, 400);
    const selectedCase=evaluationRequest?evaluationCase(payload):undefined;
    if(evaluationRequest&&!selectedCase)return json({error:'evaluation_case_not_allowed'},400);
    if(evaluationRequest&&(env.LIVE_AI!=='true'||env.TEST_MODE==='true'))return json({error:'evaluation_requires_live_baseline'},503);
    if(payload.version===6&&env.ALLOW_LIBRARY_CONTEXT!=='true')return json({error:'library_context_disabled'},503);
    if([4,5,6].includes(payload.version)&&env.LIVE_AI!=='true')return json({error:'library_requires_live_provider'},503);
    if([4,5,6].includes(payload.version)&&(env.ALLOW_LIBRARY_TOOLS!=='true'||env.ALLOW_SAVED_METADATA!=='true'))return json({error:'library_tools_disabled'},503);
    if(payload.version===3&&env.ALLOW_DISCOVERY!=='true')return json({error:'web_discovery_disabled'},503);
    if(payload.version===2&&env.ALLOW_SAVED_METADATA!=='true')return json({error:'saved_metadata_disabled'},503);
    if(payload.attachment&&!['true','verification'].includes(env.ALLOW_SELECTED_SCREENSHOT))return json({error:'selected_screenshot_disabled'},503);
    // No accidental live activation, even with a key or production ENABLED=true.
    if (env.ENVIRONMENT !== 'dev' || (env.TEST_MODE !== 'true' && env.LIVE_AI !== 'true')) return json({ error: 'provider_not_configured' }, 503);
    if (env.LIVE_AI === 'true') {
      if (!env.OPENAI_API_KEY) return json({error:'provider_not_configured'},503);
      try { if([4,5,6].includes(payload.version))libraryIntentBody(payload);else if(payload.version!==3)providerBody(payload); } catch { return json({error:'input_limit'},400); }
    }
    const fingerprint = await digest(JSON.stringify(payload));
    try {
      const ledger = env.BUDGET.get(env.BUDGET.idFromName('shared-lifetime-v1'));
      if(evaluationRequest){
        const read=await ledger.fetch(new Request('https://ledger/evaluation-status',{method:'POST',body:JSON.stringify({user})}));
        if(!read.ok)return json({error:'evaluation_budget_unverified'},503);
        const status=await read.json();
        if(!verifiedEvaluationStatus(status))return json({error:'evaluation_budget_unverified'},503);
        if(status.halted||status.availableAttempts<1)return json({error:'evaluation_allowance_unavailable'},429);
        if(status.cases.some(x=>x.caseID===selectedCase.id&&x.requestID))return json({error:'evaluation_case_already_attempted'},409);
      }
      const reservation = await ledger.fetch(new Request(evaluationRequest?'https://ledger/evaluation-reserve':'https://ledger/reserve', {
        method: 'POST', body: JSON.stringify({ user, id: payload.requestID, fingerprint, amount:payload.version===3?WEB_RESERVATION:RESERVATION,...(evaluationRequest?{runID:EVALUATION_RUN,caseID:selectedCase.id}:{}) })
      }));
      if (!reservation.ok) return json({ error: reservation.status === 409 ? 'duplicate_request' : 'budget_unavailable' }, reservation.status);
      if (payload.version === 3) {
        // Code updates may briefly pair a new Worker with the old $0.05 ledger.
        // Only a committed proof for THIS request authorizes the larger web spend.
        let proof;
        try { proof = await reservation.json(); } catch { return json({error:'budget_reservation_unverified'},503); }
        if (proof?.reserved !== true || proof.protocol !== 2 ||
            proof.reservationMicroUSD !== WEB_RESERVATION || proof.requestID !== payload.requestID || (evaluationRequest && (proof.evaluationRunID!==EVALUATION_RUN||proof.caseID!==selectedCase.id))) {
          return json({error:'budget_reservation_unverified'},503);
        }
      }
    } catch { return json({ error: 'budget_unavailable' }, 503); }
    if (env.LIVE_AI === 'true') {
      const ledger = env.BUDGET.get(env.BUDGET.idFromName('shared-lifetime-v1'));
      try {
        let research;const evaluationDate=new Date();
        const result = [4,5,6].includes(payload.version) ? await callLibraryIntent(payload,env) : payload.version===3 ? await callDiscovery(payload,env,fetch,evaluationDate,()=>performance.now(),evaluationRequest?value=>{research=value}:undefined) : await callOpenAI(payload,env);
        const recorded = await ledger.fetch(new Request('https://ledger/settle',{method:'POST',body:JSON.stringify({user,id:payload.requestID,usage:result.usage})}));
        if (!recorded.ok) throw Error('usage_recording_failed');
        const receipt = await recorded.json();
        let evaluation;
        if(evaluationRequest){
          const started=performance.now();
          try { evaluation=compareEvaluation(result.answer,localExtractionCandidate(research,payload.criteria,evaluationDate),result.timings,performance.now()-started); }
          catch { evaluation={protocol:1,runID:EVALUATION_RUN,candidateKind:'local-extraction',candidate:{status:'rejected'},baselineCalls:2,candidateAdditionalCalls:0,stop:true,humanSourceReviewRequired:true}; }
          evaluation.caseID=selectedCase.id;
          evaluation.asOf=evaluationDate.toISOString().slice(0,10);
          const finished=await ledger.fetch(new Request('https://ledger/evaluation-finish',{method:'POST',body:JSON.stringify({user,id:payload.requestID,caseID:selectedCase.id,stop:evaluation.stop})}));
          if(!finished.ok)throw Error('usage_recording_failed');
        }
        return json({...result.answer,model:MODEL,usage:result.usage,budget:receipt.budget,...(evaluation?{evaluation}:{})},200,result.timings?{'Server-Timing':Object.entries(result.timings).filter(([key,value])=>['research','extraction','validation','overall'].includes(key)&&Number.isFinite(value)&&value>=0&&value<=240000).map(([key,value])=>`${key};dur=${value}`).join(', ')}:{});
      } catch (error) {
        // Hold the full reservation on all unknown, cancelled or failed attempts.
        if(evaluationRequest){try{await ledger.fetch(new Request('https://ledger/evaluation-finish',{method:'POST',body:JSON.stringify({user,id:payload.requestID,caseID:selectedCase.id,stop:true})}))}catch{}}
        const code = error instanceof Error ? error.message : '';
        const reason = /^web_calls_(missing|limit|status|shape)$/.test(code) || /^web_(upstream_[45][0-9]{2}|response|response_limit|usage|calls|extraction|input_limit)$/.test(code) || /^invalid_answer_(shape|paragraph_ids|sources|span|place|length)$/.test(code) || /^upstream_[45][0-9]{2}_[a-z_]{1,60}$/.test(code) || ['invalid_usage','invalid_answer','refused_or_incomplete','upstream_limit','usage_recording_failed','image_count_unavailable','image_count_exceeds_limit'].includes(code) ? code : 'upstream_unavailable';
        const diagnostic=payload.version===3&&/^web_calls_(missing|limit|status|shape)$/.test(reason)?error.publicDiagnostic:undefined;
        return json({error:'model_request_failed_reservation_held',reason,...(diagnostic?{diagnostic}:{})},502);
      }
    }
    // Validated candidate IDs only; app reconstructs identities from its own evidence.
    return json({ version: 1, summary: 'Hosted proxy mock response. No live AI call was made.', candidateIDs: payload.candidates.map(x => x.id) });
  }
};

export class BudgetLedger {
  constructor(state) { this.storage = state.storage; }
  async fetch(request) {
    const p = await request.json();
    const route=new URL(request.url).pathname;
    const evalPrefix='evaluation:'+EVALUATION_RUN;
    if(route==='/evaluation-status'){
      if(p.user!==EVALUATION_TESTER)return json({},403);
      return this.storage.transaction(async tx=>{
        const total=(await tx.get('total'))??0,userTotal=(await tx.get('user:'+p.user))??0,count=(await tx.get(evalPrefix+':count'))??0;
        const halted=(await tx.get(evalPrefix+':halted'))===true;
        const cases=await Promise.all(EVALUATION_CASES.map(async c=>{
          const record=await tx.get(evalPrefix+':case:'+c.id);
          if(!record)return {caseID:c.id,state:'not-attempted'};
          const requestRecord=await tx.get('request:'+p.user+':'+record.requestID);
          return {caseID:c.id,requestID:record.requestID,state:record.state,usageRecorded:!!requestRecord?.usage};
        }));
        if(![total,userTotal,count].every(Number.isSafeInteger)||total<0||total>TOTAL_CAP||userTotal<0||userTotal>USER_CAP||userTotal>total||count<0||count>EVALUATION_MAX||cases.filter(x=>x.requestID).length!==count)return json({},503);
        return json({protocol:1,readOnly:true,runID:EVALUATION_RUN,reservationMicroUSD:WEB_RESERVATION,maximumAttempts:EVALUATION_MAX,maximumReservationMicroUSD:600000,totalCapMicroUSD:TOTAL_CAP,userCapMicroUSD:USER_CAP,totalReservedMicroUSD:total,userReservedMicroUSD:userTotal,totalRemainingMicroUSD:TOTAL_CAP-total,userRemainingMicroUSD:USER_CAP-userTotal,attemptedCount:count,halted,cases,availableAttempts:halted||cases.some(x=>x.state==='reserved')?0:Math.max(0,Math.min(EVALUATION_MAX-count,Math.floor((TOTAL_CAP-total)/WEB_RESERVATION),Math.floor((USER_CAP-userTotal)/WEB_RESERVATION)))});
      });
    }
    if(route==='/evaluation-finish'){
      if(p.user!==EVALUATION_TESTER||!uuid.test(p.id??'')||!EVALUATION_CASES.some(x=>x.id===p.caseID)||typeof p.stop!=='boolean')return json({},400);
      return this.storage.transaction(async tx=>{
        const key=evalPrefix+':case:'+p.caseID,record=await tx.get(key);
        if(!record||record.requestID!==p.id||(!p.stop&&record.state==='stopped'))return json({},409);
        if(p.stop)await tx.put(evalPrefix+':halted',true);
        await tx.put(key,{...record,state:p.stop?'stopped':'complete'});
        return json({recorded:true});
      });
    }
    if (new URL(request.url).pathname === '/settle') {
      const usage = p.usage;
      if (!/^[a-z0-9-]{1,40}$/.test(p.user ?? '') || !uuid.test(p.id ?? '') || !Number.isSafeInteger(usage?.estimatedMicroUSD) || usage.estimatedMicroUSD < 0 || usage.estimatedMicroUSD > WEB_RESERVATION) return json({},400);
      return this.storage.transaction(async tx => {
        const key = `request:${p.user}:${p.id}`, record = await tx.get(key);
        if (!record) return json({},404);
        if (usage.estimatedMicroUSD > record.reserved) return json({},400);
        if (!record.usage) { await tx.put(key,{...record,usage});await tx.put('estimatedUsage',((await tx.get('estimatedUsage'))??0)+usage.estimatedMicroUSD); }
        return json({recorded:true,budget:{reservedMicroUSD:(await tx.get('total'))??0,userReservedMicroUSD:(await tx.get(`user:${p.user}`))??0,estimatedUsageMicroUSD:(await tx.get('estimatedUsage'))??0}});
      });
    }
    if (!/^[a-z0-9-]{1,40}$/.test(p.user ?? '') || !uuid.test(p.id ?? '') || !/^[a-f0-9]{64}$/.test(p.fingerprint ?? '')) return json({}, 400);
    // Integer micro-USD, conservative reservation held permanently in this scaffold.
    // $5 lifetime shared, $2.50/user. $0.05 held permanently for each upstream attempt.
    // Fixed text model/body/output ceilings are enforced before dispatch; no refunds.
    const evaluation=route==='/evaluation-reserve';
    if(evaluation&&(p.user!==EVALUATION_TESTER||p.runID!==EVALUATION_RUN||!EVALUATION_CASES.some(x=>x.id===p.caseID)||p.amount!==WEB_RESERVATION))return json({},400);
    const amount=p.amount??RESERVATION;
    if (![RESERVATION,WEB_RESERVATION].includes(amount)) return json({},400);
    const minute = Math.floor((this.now?.() ?? Date.now()) / 60000);
    const status = await this.storage.transaction(async tx => {
      const key = `request:${p.user}:${p.id}`;
      if (await tx.get(key)) return 409;
      if(evaluation){
        if(await tx.get(evalPrefix+':case:'+p.caseID))return 409;
        const count=(await tx.get(evalPrefix+':count'))??0;
        if(await tx.get(evalPrefix+':halted')||!Number.isSafeInteger(count)||count<0||count>=EVALUATION_MAX)return 429;
      }
      const recent = (await tx.get(`rate:${p.user}`)) ?? { minute, count:0 };
      const count = recent.minute === minute ? recent.count : 0;
      if (count >= 6) return 429;
      const total = (await tx.get('total')) ?? 0;
      const userTotal = (await tx.get(`user:${p.user}`)) ?? 0;
      if (total + amount > TOTAL_CAP || userTotal + amount > USER_CAP) return 429;
      await tx.put(`rate:${p.user}`, { minute, count:count + 1 });
      await tx.put('total', total + amount);
      await tx.put(`user:${p.user}`, userTotal + amount);
      await tx.put(key, { fingerprint: p.fingerprint, reserved: amount });
      if(evaluation){
        await tx.put(evalPrefix+':count',((await tx.get(evalPrefix+':count'))??0)+1);
        await tx.put(evalPrefix+':case:'+p.caseID,{requestID:p.id,state:'reserved'});
      }
      return 200;
    });
    return json({ reserved: status === 200, protocol:2, reservationMicroUSD:status===200?amount:0, requestID:p.id,...(evaluation&&status===200?{evaluationRunID:EVALUATION_RUN,caseID:p.caseID}:{}) }, status);
  }
}
