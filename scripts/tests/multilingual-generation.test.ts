import { deepStrictEqual, notStrictEqual, ok, rejects, strictEqual, throws } from "node:assert"
import { generationFingerprint, validateGenerationSpec, type GenerationSpec } from "../../supabase/functions/_shared/generation/spec.ts"
import { sha256, validateLearningMaterial } from "../../supabase/functions/_shared/content-contracts/memory.ts"
import { buildMultilingualPrompt, parseMultilingualContent } from "../../supabase/functions/_shared/generation/content.ts"
import { requestWithFallback } from "../../supabase/functions/_shared/generate-memory-v2/providers.ts"
import { isDefiniteGenerationRollback } from "../../supabase/functions/_shared/generate-memory-v2/repository.ts"

const spec: GenerationSpec = { schemaVersion: 1, catalogVersion: 1, targetLanguage: "en", translationLanguage: "zh-Hans",
  teachingLocale: "en-US", level: "starter", generationFormat: "dual_tabs_v1" }

Deno.test("multilingual generation: ten supported pairs and strict version/locale/level validation", () => {
  let count = 0
  const locale = { en: "en-US", es: "es-419", ja: "ja-JP", fr: "fr-FR" }
  for (const target of ["en", "es", "ja", "fr"] as const) {
    for (const translation of ["zh-Hans", "en", "es", "ja", "fr"]) {
      const valid = translation === "zh-Hans" || (target === "en" && ["es", "ja", "fr"].includes(translation)) || (target !== "en" && translation === "en")
      const candidate = { ...spec, targetLanguage: target, translationLanguage: translation, teachingLocale: locale[target] }
      if (valid) { validateGenerationSpec(candidate); count++ } else throws(() => validateGenerationSpec(candidate))
    }
  }
  strictEqual(count, 10)
  for (const patch of [{schemaVersion: 2}, {catalogVersion: 2}, {teachingLocale: "en-GB"}, {level: "easy"}, {generationFormat: "legacy_v1"}]) {
    throws(() => validateGenerationSpec({...spec, ...patch}))
  }
})

Deno.test("multilingual generation: canonical fingerprint binds original bytes and immutable spec", async () => {
  const bytes = new Uint8Array([1,2,3])
  const fingerprint = await generationFingerprint(spec, bytes)
  strictEqual(fingerprint.length, 64)
  strictEqual(fingerprint, await generationFingerprint(JSON.parse(JSON.stringify(spec)), bytes))
  notStrictEqual(fingerprint, await generationFingerprint({...spec, level: "advanced"}, bytes))
  notStrictEqual(fingerprint, await generationFingerprint({...spec, translationLanguage: "ja"}, bytes))
  notStrictEqual(fingerprint, await generationFingerprint(spec, new Uint8Array([1,2,4])))
})

Deno.test("multilingual generation: Japanese material digest, exact surfaces and readings are mandatory", async () => {
  const text = "猫です。"
  const material = {schemaVersion: 1, policyVersion: 1, textDigest: await sha256(text), segments: [
    {id:"1", surface:"猫", reading:"ねこ", kind:"word", canBlank:true},
    {id:"2", surface:"です", kind:"phrase", canBlank:false}, {id:"3", surface:"。", kind:"punctuation", canBlank:false},
  ]}
  deepStrictEqual(await validateLearningMaterial(material, text, true), material)
  await rejects(() => validateLearningMaterial({...material, textDigest: "0".repeat(64)}, text, true))
  await rejects(() => validateLearningMaterial({...material, segments: material.segments.slice(1)}, text, true))
  await rejects(() => validateLearningMaterial({...material, segments: material.segments.map(s => ({...s, reading:undefined}))}, text, true))
  await rejects(() => validateLearningMaterial({...material, segments: material.segments.map(s => ({...s, canBlank:true}))}, text, true))
})

Deno.test("multilingual generation: bounded parser validates both groups and provider fallback keeps the same spec", async () => {
  const sentences = Array.from({length:6}, (_,i) => ({targetText:"This is a cat.",translationText:"这是一只猫。",
    presentationGroup:i<3?"what_i_see":"what_i_say",learningTopicIDs:["pets_and_animals"],expressionPurpose:"Describing a pet."}))
  const raw = JSON.stringify({sentences, tags:["pets_and_animals"]})
  const parsed = await parseMultilingualContent(raw, spec)
  strictEqual(parsed?.sentences.length, 6)
  strictEqual(new Set(parsed?.sentences.map(s => s.id)).size, 6)
  strictEqual(await parseMultilingualContent(JSON.stringify({sentences:sentences.slice(1), tags:[]}), spec), null)
  strictEqual(await parseMultilingualContent(raw.replaceAll("what_i_say", "what_i_see"), spec), null)
  const prompts: string[] = []
  let requests=0
  const result = await requestWithFallback({ imageBase64:"AA==", promptText:buildMultilingualPrompt(spec), generationFormat:"dual_tabs_v1",
    mimoBaseURL:"https://unused.invalid",kimiBaseURL:"https://unused.invalid",mimoApiKey:"test",kimiApiKey:"test",
    parseContent: content => parseMultilingualContent(content, spec), fetcher: async (_input, init) => {
      prompts.push(JSON.parse(String((init as RequestInit)?.body)).messages[1].content[1].text)
      return Response.json({choices:[{message:{content:++requests===1?"bad":raw}}]})
    } })
  strictEqual(result.ok,true)
  strictEqual(requests,2)
  strictEqual(prompts[0],prompts[1])
  strictEqual(result.ok && result.provider,"kimi")
})

Deno.test("multilingual generation: Spanish and French produce exact accent/elision study material, not English fallback",async()=>{
  for(const [language,locale,text] of [["es","es-419","El café está caliente."],["fr","fr-FR","L'été est très chaud."]] as const) {
    const course:GenerationSpec={...spec,targetLanguage:language,teachingLocale:locale}
    const segments=text.match(/[^\s.]+|\s+|\./gu)!.map((surface,i)=>({id:String(i),surface,
      kind:/^\s+$/.test(surface)?"whitespace":surface==="."?"punctuation":"word",canBlank:/[\p{L}]/u.test(surface)}))
    const sentences=Array.from({length:6},(_,i)=>({targetText:text,translationText:"练习句子。",
      learningTopicIDs:[],presentationGroup:i<3?"what_i_see":"what_i_say",expressionPurpose:"Describing summer.",
      learningMaterial:{schemaVersion:1,policyVersion:1,segments}}))
    const raw=JSON.stringify({sentences,tags:[]})
    const parsed=await parseMultilingualContent(raw,course)
    strictEqual(parsed?.sentences.length,6)
    deepStrictEqual(parsed?.sentences[0].learningMaterial?.segments,segments)
    strictEqual(parsed?.sentences[0].learningMaterial?.textDigest,await sha256(text))
    const missing=structuredClone(sentences) as any[]; delete missing[0].learningMaterial
    strictEqual(await parseMultilingualContent(JSON.stringify({sentences:missing,tags:[]}),course),null)
    const invalid=structuredClone(sentences); invalid[0].learningMaterial.segments[0].surface="rewritten"
    strictEqual(await parseMultilingualContent(JSON.stringify({sentences:invalid,tags:[]}),course),null)
    ok(buildMultilingualPrompt(course).includes("learningMaterial"))
    ok(buildMultilingualPrompt(course,"closed").includes("closed question"))
    ok(buildMultilingualPrompt(course,"open").includes("open question"))
    ok(buildMultilingualPrompt(course).includes("not a photo caption"))
  }
})

Deno.test("multilingual generation: unknown material keys and indeterminate SQL outcomes fail safely",async()=>{
  const text="A cat."
  const material={schemaVersion:1,policyVersion:1,textDigest:await sha256(text),segments:[{id:"1",surface:text,kind:"phrase",canBlank:true}]}
  await rejects(()=>validateLearningMaterial({...material,prompt:"unexpected"},text))
  await rejects(()=>validateLearningMaterial({...material,segments:[{...material.segments[0],script:"unexpected"}]},text))
  for(const code of [undefined,"","PGRST000","08006","08007","40003","XX000"]) strictEqual(isDefiniteGenerationRollback({code}),false)
  for(const code of ["23514","23505","22023","42501","P0001","40001","40P01","57014"]) strictEqual(isDefiniteGenerationRollback({code}),true)
})
