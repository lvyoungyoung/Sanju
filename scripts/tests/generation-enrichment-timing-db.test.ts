import { strictEqual, rejects } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

Deno.test("timing reports are owner-scoped, bounded and cannot overwrite a newer attempt", async () => {
  const db = new PGlite();
  const owner = "10000000-0000-0000-0000-000000000001";
  const other = "10000000-0000-0000-0000-000000000002";
  const job = "20000000-0000-0000-0000-000000000001";
  const memory = "30000000-0000-0000-0000-000000000001";
  const guestJob = "40000000-0000-0000-0000-000000000001";
  const report = JSON.stringify({version:1,stages:[{stage:"job_total",outcome:"completed",ms:30}]});
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
      create table generation_enrichment_jobs(id uuid primary key, user_id uuid, memory_id uuid, guest_job_id uuid, status text, attempts int);
      insert into generation_enrichment_jobs values ('${job}','${owner}','${memory}',null,'completed',1);`);
    await db.exec(await Deno.readTextFile(new URL("../../supabase/migrations/20260926003000_add_enrichment_timing_diagnostics.sql", import.meta.url)));
    const read = async (user: string, mid: string | null, gid: string | null = null) => {
      await db.query("select set_config('test.uid',$1,false)",[user]);
      return (await db.query<any>("select get_generation_enrichment_timing($1,$2) as value",[mid,gid])).rows[0].value;
    };
    const save = (attempt: number, value = report) => db.query("select save_generation_enrichment_timing($1,$2,$3::jsonb)",[job,attempt,value]);
    strictEqual((await read(owner,memory)).report, null);
    await save(1);
    strictEqual((await read(owner,memory)).report.stages[0].ms,30);
    strictEqual(await read(other,memory),null);
    strictEqual(await read("",memory),null);
    strictEqual(await read(owner,null),null);
    strictEqual(await read(owner,memory,guestJob),null);
    await db.query("update generation_enrichment_jobs set attempts=2 where id=$1",[job]);
    strictEqual((await read(owner,memory)).report,null);
    await save(2);
    await save(1, JSON.stringify({version:1,stages:[]}));
    strictEqual((await read(owner,memory)).report.stages[0].ms,30);
    await rejects(save(2,JSON.stringify({payload:"x".repeat(17000)})),/check constraint/);
    await db.query("update generation_enrichment_jobs set memory_id=null,guest_job_id=$1 where id=$2",[guestJob,job]);
    strictEqual((await read(owner,null,guestJob)).report.stages[0].ms,30);
    strictEqual(await read(other,null,guestJob),null);
    for (const role of ["authenticated","anon"]) {
      strictEqual((await db.query<any>("select has_function_privilege($1,'save_generation_enrichment_timing(uuid,integer,jsonb)','EXECUTE') as ok",[role])).rows[0].ok,false);
      strictEqual((await db.query<any>("select has_table_privilege($1,'generation_enrichment_timings','SELECT') as ok",[role])).rows[0].ok,false);
    }
    strictEqual((await db.query<any>("select has_function_privilege('authenticated','get_generation_enrichment_timing(uuid,uuid)','EXECUTE') as ok")).rows[0].ok,true);
    strictEqual((await db.query<any>("select has_function_privilege('anon','get_generation_enrichment_timing(uuid,uuid)','EXECUTE') as ok")).rows[0].ok,false);
    await db.query("delete from generation_enrichment_jobs where id=$1",[job]);
    strictEqual((await db.query<any>("select count(*)::int as n from generation_enrichment_timings")).rows[0].n,0);
  } finally { await db.close() }
});
