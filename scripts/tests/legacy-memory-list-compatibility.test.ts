import { deepStrictEqual, rejects, strictEqual } from "node:assert"
import { setupDialogueDatabase } from "./helpers/dialogue-database.ts"

const root = new URL("../../supabase/migrations/", import.meta.url)
const owner = "10000000-0000-4000-8000-000000000001"

Deno.test("legacy memory reads survive metadata retirement without restoring classification", async () => {
  const db = await setupDialogueDatabase()
  try {
    const memoryID = crypto.randomUUID(), sentenceID = crypto.randomUUID()
    await db.query("insert into memories(id,user_id,image_url) values($1,$2,$3)", [memoryID, owner, `${owner}/photo.jpg`])
    await db.query(`insert into memory_sentences(id,memory_id,sort_order,english,chinese,is_favorite)
      values($1,$2,0,'Hello.','你好。',true)`, [sentenceID, memoryID])
    await db.exec(await Deno.readTextFile(new URL("20261016000000_remove_sentence_metadata.sql", root)))
    const legacyQuery = `select id,sort_order,english,chinese,learning_topic_ids,presentation_group,is_favorite
      from memory_sentences where memory_id=$1`
    await rejects(() => db.query(legacyQuery, [memoryID]), /learning_topic_ids/)

    const repair = await Deno.readTextFile(new URL("20261020000000_restore_legacy_sentence_topic_column.sql", root))
    await db.exec(repair)
    await db.exec(repair)
    const rows = (await db.query(legacyQuery, [memoryID])).rows
    strictEqual(rows.length, 1)
    deepStrictEqual(rows[0], { id: sentenceID, sort_order: 0, english: "Hello.", chinese: "你好。",
      learning_topic_ids: [], presentation_group: null, is_favorite: true })
    await db.exec(`set test.user_id='${owner}'; set role authenticated;`)
    strictEqual((await db.query(legacyQuery, [memoryID])).rows.length, 1)
    await db.query("update memory_sentences set is_favorite=false where id=$1", [sentenceID])
    strictEqual((await db.query<{ is_favorite: boolean }>(legacyQuery, [memoryID])).rows[0].is_favorite, false)
    await db.exec("set test.user_id='10000000-0000-4000-8000-000000000002';")
    strictEqual((await db.query(legacyQuery, [memoryID])).rows.length, 0)
    await db.exec("reset role;")
    const newID = crypto.randomUUID()
    await db.query(`insert into memory_sentences(id,memory_id,sort_order,english,chinese,is_favorite)
      values($1,$2,1,'Thank you.','谢谢。',false)`, [newID, memoryID])
    deepStrictEqual((await db.query("select learning_topic_ids from memory_sentences where id=$1", [newID])).rows,
      [{ learning_topic_ids: [] }])
    const retired = await db.query(`select to_regclass('public.sentence_embeddings') as embeddings,
      to_regclass('public.generation_enrichment_jobs') as jobs,
      to_regprocedure('public.learning_topic_ids_from_json(jsonb)') as classifier`)
    deepStrictEqual(retired.rows, [{ embeddings: null, jobs: null, classifier: null }])
  } finally {
    await db.close()
  }
})
