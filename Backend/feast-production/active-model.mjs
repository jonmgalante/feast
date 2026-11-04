// New requests only. Historical profiles and opaque continuations retain their model.
export const SUPPORTED_MODELS=Object.freeze(['gpt-6-astra','gpt-6.1-sol']);
export const ACTIVE_MODEL='gpt-6.1-sol';
export const ACTIVE_EFFORT='medium';
const prefix=ACTIVE_MODEL==='gpt-6-astra'?'astra':'sol';
export const ACTIVE_PROFILES=Object.freeze({agent:prefix+'AgentStepV1',research:prefix+'ResearchStageV1',extraction:prefix+'ExtractionStageV1'});
export function modelFrame(value){
 if(Array.isArray(value))return {model:'gpt-6-astra',items:value};
 if(!value||Object.keys(value).sort().join(',')!=='items,model,version'||value.version!==1||!SUPPORTED_MODELS.includes(value.model)||!Array.isArray(value.items))throw Error('conversation_model_frame');
 return value;
}
export function continuationModel(p,decode,initialModel=ACTIVE_MODEL){if(!SUPPORTED_MODELS.includes(initialModel))throw Error('conversation_model');return p.step===0?initialModel:modelFrame(decode(p.continuation)).model}
export const agentProfile=model=>model==='gpt-6-astra'?'astraAgentStepV1':model==='gpt-6.1-sol'?'solAgentStepV1':null;
