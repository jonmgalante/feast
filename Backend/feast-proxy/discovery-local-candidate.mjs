// Comparison-only candidate: invoked solely by the explicitly gated dev evaluation route.
// Normal discovery never uses it. No fetch, retries or live-path fallback.
import {citedBlocks,checkedOpenings,webCost} from './discovery.mjs';
import {MODEL} from './openai.mjs';
export function localExtractionCandidate(research,criteria,now=new Date()) {
 const usage=webCost(research,{status:'completed',model:MODEL,usage:{input_tokens:0,output_tokens:0},output:[]});
 const blocks=citedBlocks(research),raw=[];
 if(criteria.intent==='recommendations')return {places:[],usage,unsupported:true};
 for(const block of blocks){
  // Never truncate an excerpt or infer the event date from a publication stamp.
  if(block.text.length>600)continue;
  const dates=[...new Set(block.text.match(/\b\d{4}-\d{2}-\d{2}\b/g)??[])];
  if(dates.length!==1)continue;
  const name=block.text.match(/^\*\*([^*]{1,200})\*\*/)?.[1]??block.text.match(/^(.{1,200}?)\s+(?:cafe|café|bakery|bar|restaurant|dessert)\b/i)?.[1];
  if(!name)continue;
  const opened=/\b(?:opened|debuted|launched)\s+(?:on\s+)?\*{0,2}\d{4}-\d{2}-\d{2}\b/i.test(block.text);
  const announced=/\b(?:will open|opens|opening|scheduled to open)\s+on\s+\*{0,2}\d{4}-\d{2}-\d{2}\b/i.test(block.text);
  if(!opened&&!announced)continue;
  raw.push({name,cuisine:criteria.cuisine??null,region:criteria.region,category:criteria.category,sourceURL:block.url,openingDate:dates[0],openingKind:opened?'opened':'announced',evidence:block.text});
 }
 return {places:checkedOpenings({places:raw.slice(0,3)},blocks,criteria,now),usage,unsupported:false};
}
