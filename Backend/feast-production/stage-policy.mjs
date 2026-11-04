// Immutable V1 profiles. Never change these bounds for already persisted records.
export const STAGE_POLICY=Object.freeze({
 solAgentStepV1:Object.freeze({model:'gpt-6.1-sol',maxInput:32768,maxOutput:8192,webCalls:0,inputRate:4,outputRate:20}),
 solResearchStageV1:Object.freeze({model:'gpt-6.1-sol',maxInput:262144,maxOutput:8192,webCalls:1,inputRate:4,outputRate:20}),
 solExtractionStageV1:Object.freeze({model:'gpt-6.1-sol',maxInput:8192,maxOutput:8192,webCalls:0,inputRate:4,outputRate:20}),
 astraAgentStepV1:Object.freeze({model:'gpt-6-astra',maxInput:32768,maxOutput:8192,webCalls:0}),
 astraResearchStageV1:Object.freeze({model:'gpt-6-astra',maxInput:262144,maxOutput:8192,webCalls:1}),
 astraExtractionStageV1:Object.freeze({model:'gpt-6-astra',maxInput:8192,maxOutput:8192,webCalls:0})
});
export const stageMaximum=p=>Math.ceil((p.maxInput*(p.inputRate??20)+p.maxOutput*(p.outputRate??100)+p.webCalls*10000)*11/10);
export const STAGE_HOLDS=Object.freeze(Object.fromEntries(Object.entries(STAGE_POLICY).map(([name,p])=>[name,stageMaximum(p)])));
export function stageCost(usage,profile){
 const p=STAGE_POLICY[profile];
 if(!p||!Array.isArray(usage)||usage.length!==1)throw Error('stage_usage_shape');
 const c=usage[0];
 if(!c||Object.keys(c).sort().join(',')!=='inputTokens,model,outputTokens,webCalls'||c.model!==p.model||!Number.isSafeInteger(c.inputTokens)||c.inputTokens<0||c.inputTokens>p.maxInput||!Number.isSafeInteger(c.outputTokens)||c.outputTokens<0||c.outputTokens>p.maxOutput||c.webCalls!==p.webCalls)throw Error('stage_usage_limit');
 const cost=Math.ceil((c.inputTokens*(p.inputRate??20)+c.outputTokens*(p.outputRate??100)+c.webCalls*10000)*11/10);
 if(cost>STAGE_HOLDS[profile])throw Error('stage_usage_limit');return cost;
}
