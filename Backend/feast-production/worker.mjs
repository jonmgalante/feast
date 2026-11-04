import {WorkerEntrypoint} from 'cloudflare:workers';
import {brokerAnswer,productionStatus} from './broker.mjs';
export {ProductionLedger} from './production-ledger.mjs';
export {default} from './public-handler.mjs';
// Private named Service Binding only. No HTTP route accepts owner credentials on public production.
export class OwnerValidationRPC extends WorkerEntrypoint {
 async answer(payload,userHash){const r=await brokerAnswer(payload,userHash,this.env);return {status:r.status,body:await r.json()}}
 async status(userHash){const r=await productionStatus(this.env,userHash);return {status:r.status,body:await r.json()}}
}
