// Bounded, content-free request-local measurements. No payloads, identifiers,
// URLs, errors or secrets are accepted. Nested stages are not additive wall time.
const STAGES=new Set(['preparation','inputCount','provider','ledger','decode','assembly','evidence']);
const COUNTERS=new Set(['requestBytes','responseBytes','inputTokens','outputTokens','cachedInputTokens','reasoningTokens','evidenceSourcesSeen','evidenceSourcesRetained','evidenceSourcesOmitted','evidenceRequiredSources','evidenceTextUnits','evidenceActions','evidenceBlocks']);
export class PerformanceMeasurements {
 constructor(now=()=>performance.now()){this.now=now;this.stages={};this.counters={}}
 start(){return this.now()}
 record(stage,start){
  const milliseconds=this.now()-start;
  if(!STAGES.has(stage)||!Number.isFinite(milliseconds)||milliseconds<0||milliseconds>3600000)return;
  const item=this.stages[stage]??{milliseconds:0,calls:0};
  if(item.calls>=64)return;
  item.milliseconds=Math.round((item.milliseconds+milliseconds)*1000)/1000;item.calls++;this.stages[stage]=item;
 }
 async measure(stage,work){const start=this.start();try{return await work()}finally{this.record(stage,start)}}
 count(key,value){if(!COUNTERS.has(key)||!Number.isSafeInteger(value)||value<0||value>16777216)return;this.counters[key]=Math.min((this.counters[key]??0)+value,16777216)}
 usage(value){const u=value?.usage;this.count('inputTokens',u?.input_tokens);this.count('outputTokens',u?.output_tokens);this.count('cachedInputTokens',u?.input_tokens_details?.cached_tokens);this.count('reasoningTokens',u?.output_tokens_details?.reasoning_tokens)}
 serialize(value){const start=this.start();try{const text=JSON.stringify(value);this.count('requestBytes',new TextEncoder().encode(text).byteLength);return text}finally{this.record('preparation',start)}}
 snapshot(){return {version:1,stages:structuredClone(this.stages),counters:{...this.counters}}}
}
