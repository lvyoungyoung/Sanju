import { deepStrictEqual, ok, strictEqual } from "node:assert"

const root = new URL("../../supabase/functions/_shared/", import.meta.url)
const source = await Deno.readTextFile(new URL("generation-enrichment.ts", root))
const api = await import("data:application/typescript," + encodeURIComponent(`
  import {fetchWithinDeadline, fetchWithTimeout} from ${JSON.stringify(new URL("fetch-with-timeout.ts", root).href)};
  import {generateSentenceMetadata, parseSentenceMetadata, readEmbeddedSentenceMetadata} from ${JSON.stringify(new URL("sentence-metadata.ts", root).href)};
  import {EnrichmentTiming} from ${JSON.stringify(new URL("generation-enrichment-timing.ts", root).href)};
  import {hasTeachingLocale, supportsGeneration} from ${JSON.stringify(new URL("languages/main.ts", root).href)};
  const Deno={env:{get:()=>"offline-fixture"}};
  function createClient(){throw new Error("No network client allowed")}
  ${source.replace(/^import .*\n/gm, "")}
`))

const context = { schemaVersion: 2, targetLanguage: "fr", translationLanguage: "en", teachingLocale: "fr-FR" }

Deno.test("multilingual enrichment uses versioned vectors and never calls English metadata/matching",async()=>{
  const calls:string[]=[], requests:string[][]=[], published:any[]=[]
  const client={rpc:async(name:string,args:any)=>{
    calls.push(name)
    if(name==="claim_scoped_generation_enrichment") return {data:[{id:"job",attempts:1,lease_token:"lease",
      content_schema_version:2,content_context:context,sentences:[{id:"sentence",targetText:"Le café est chaud.",
        translationText:"The coffee is hot.",expressionPurpose:"Décrire une boisson.",learningTopicIDs:[]}]}],error:null}
    if(name==="complete_multilingual_generation_enrichment_v1") {published.push(...args.p_rows);return {data:true,error:null}}
    throw new Error(`Unexpected RPC ${name}`)
  }}
  const result=await api.processGenerationEnrichment(client,{userID:"owner",memoryID:"memory"},async(_url:any,init:RequestInit)=>{
    const texts=JSON.parse(String(init.body)).input.texts
    requests.push(texts)
    return Response.json({data:texts.map((_:string,index:number)=>({index,embedding:Array(1024).fill(0.01)}))})
  })
  deepStrictEqual(result,{completed:1,failed:0})
  deepStrictEqual(calls,["claim_scoped_generation_enrichment","complete_multilingual_generation_enrichment_v1"])
  strictEqual(published[0].model,"qwen3.7-text-embedding:multilingual-v1")
  ok(requests[0][0].includes("Language: fr\nTeaching locale: fr-FR\nTarget: Le café est chaud."))
  deepStrictEqual(requests[1],["Décrire une boisson."])
})

Deno.test("multilingual enrichment rejects unknown versions and mismatched language/locale before provider calls",async()=>{
  for(const [version,languageContext] of [[99,context],[2,{...context,teachingLocale:"en-US"}],
    [2,{...context,translationLanguage:"ja"}],[2,null],[1,context]]) {
    let retried=0,providerCalls=0
    const result=await api.processGenerationEnrichment({rpc:async(name:string)=>{
      if(name==="claim_scoped_generation_enrichment") return {data:[{id:"job",attempts:1,lease_token:"lease",
        content_schema_version:version,content_context:languageContext,sentences:[]}],error:null}
      if(name==="retry_generation_enrichment") {retried++;return {error:null}}
      throw new Error(`Unexpected RPC ${name}`)
    }},{userID:"owner",memoryID:"memory"},()=>{providerCalls++;throw new Error("Unexpected provider")})
    deepStrictEqual(result,{completed:0,failed:1})
    strictEqual(retried,1);strictEqual(providerCalls,0)
  }
})
