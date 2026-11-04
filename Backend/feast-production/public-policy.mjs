import {ACTIVE_MODEL} from './active-model.mjs';
// Immutable historical Astra policy plus the active Sol policy.
// Retained token/tool bounds and conservative usage estimates are not a guaranteed provider-dollar ceiling.
export const ASTRA_PUBLIC_POLICY=Object.freeze({model:'gpt-6-astra',effort:'medium',profile:'publicAstraV1',maxSearchCalls:1,maxResearchInput:262144,maxExtractionInput:8192,maxResearchOutput:8192,maxExtractionOutput:8192,holdMicroUSD:8000000});
export const SOL_PUBLIC_POLICY=Object.freeze({...ASTRA_PUBLIC_POLICY,model:'gpt-6.1-sol',profile:'publicSolV1',holdMicroUSD:1600000,inputRate:4,outputRate:20});
export const PUBLIC_POLICY=ACTIVE_MODEL==='gpt-6-astra'?ASTRA_PUBLIC_POLICY:SOL_PUBLIC_POLICY;
export const PUBLIC_PROFILES=Object.freeze({[ASTRA_PUBLIC_POLICY.profile]:ASTRA_PUBLIC_POLICY,[SOL_PUBLIC_POLICY.profile]:SOL_PUBLIC_POLICY});
export const publicWorstCaseMicroUSD=()=>Math.ceil(((PUBLIC_POLICY.maxResearchInput+PUBLIC_POLICY.maxExtractionInput)*(PUBLIC_POLICY.inputRate??20)+(PUBLIC_POLICY.maxResearchOutput+PUBLIC_POLICY.maxExtractionOutput)*(PUBLIC_POLICY.outputRate??100)+10000)*11/10);
