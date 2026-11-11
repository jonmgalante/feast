#!/usr/bin/env node
// Content-free local inspection only. No network, credentials or live queries.
import {readFile} from 'node:fs/promises';import {answerJobsPreflight} from '../answer-jobs-preflight.mjs';import {jobDigest} from '../answer-job-contract.mjs';
const [input,...rest]=process.argv.slice(2);
if(!input||rest.length){console.error('Usage: node answer-jobs-preflight-offline.mjs COMPLETE_QUIESCED_JOBS_SNAPSHOT.json');process.exit(2)}
try{const artifact=await answerJobsPreflight(JSON.parse(await readFile(input,'utf8')));console.log(JSON.stringify({version:1,kind:'drained',artifact,artifactDigest:await jobDigest(artifact)},null,2));if(!artifact.ready)process.exitCode=3}catch(error){console.error(/^[a-z_]+$/.test(error.message)?error.message:'offline_preflight_failed');process.exitCode=1}
