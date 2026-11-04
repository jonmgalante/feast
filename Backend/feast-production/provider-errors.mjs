import {boundedResponse} from '../feast-proxy/openai.mjs';
export async function providerFailure(response,stage){
 let code=null,param=null;
 try{const value=await boundedResponse(response);if(/^[a-z_]{1,40}$/.test(value.error?.code??value.error?.type??''))code=value.error.code??value.error.type;if(/^[a-zA-Z0-9_.\[\]]{1,80}$/.test(value.error?.param??''))param=value.error.param}catch{}
 const kind=['insufficient_quota','billing_hard_limit_reached'].includes(code)?'provider_billing_limit':code==='billing_not_active'?'provider_billing_setup':response.status===429?'provider_rate_limit':[401,403].includes(response.status)?'provider_authentication':'conversation_'+stage;
 return Object.assign(Error(kind),{diagnostic:{stage,providerStatus:response.status,providerCode:code,providerParam:param}});
}

export function knownProviderRejection(error){const d=error?.diagnostic;return d?.providerStatus===429&&['insufficient_quota','rate_limit_exceeded','billing_hard_limit_reached','billing_not_active'].includes(d.providerCode)||d?.providerStatus===401&&d.providerCode==='invalid_api_key';}
