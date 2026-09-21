import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
const migration = await read(
  "supabase/migrations/20260921000000_use_device_study_time_zone.sql",
);
const matchingTests = await read(
  "scripts/tests/semantic-study-scene-matching.test.ts",
);
const schema = matchingTests.match(/const schema = `([\s\S]*?)`;/)?.[1];
if (!schema) throw new Error("Missing database fixture");
const owner = "10000000-0000-0000-0000-000000000001";
const memory = "20000000-0000-0000-0000-000000000001";
const scene = "30000000-0000-0000-0000-000000000001";
const ids = [1, 2, 3, 4].map((index) =>
  "40000000-0000-0000-0000-" + String(index).padStart(12, "0")
);
const functionSource = (source: string, name: string) => {
  const match = source.match(
    new RegExp(
      `create (?:or replace )?function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
      "i",
    ),
  );
  if (!match) throw new Error(name);
  return match[0];
};

Deno.test("study RPCs use request-local calendar days without changing old contracts", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(schema);
    await db.exec(`
      alter table sentence_study_progress
        add column learning_step integer not null default 0,
        add column mastered_review_count integer not null default 0,
        add column wrong_count integer not null default 0,
        add column last_result text,
        add column last_studied_at timestamptz,
        add column updated_at timestamptz default now(),
        add constraint sentence_study_progress_user_id_sentence_id_scope_key unique(user_id, sentence_id, study_scope);
    `);
    const oldDefinitions: Record<string, string[]> = {
      "20260811002000_scope_sentence_study_progress.sql": [
        "get_sentence_study_queue",
        "count_sentence_study_queue",
        "count_sentence_studied_today_reviewable",
        "get_sentence_studied_today_queue",
      ],
      "20260424004000_sentence_study_today_count.sql": [
        "count_sentence_studied_today",
      ],
      "20260812004000_remove_sentence_classification.sql": [
        "merge_local_sentence_study_progress",
        "record_sentence_study_result",
      ],
      "20260811003000_add_user_study_scenes.sql": [
        "get_study_scene_queue",
        "get_studied_today_scene_queue",
      ],
      "20260822010000_add_study_scene_cover_memory.sql": [
        "get_study_scenes",
        "get_study_scene_summary_for_owner",
      ],
    };
    for (const [file, names] of Object.entries(oldDefinitions)) {
      const source = await read("supabase/migrations/" + file);
      for (const name of names) await db.exec(functionSource(source, name));
    }
    await db.exec(
      "revoke all on function get_study_scene_summary_for_owner(uuid,uuid) from public, anon, authenticated; grant execute on function get_study_scene_summary_for_owner(uuid,uuid) to service_role",
    );
    await db.exec(migration);

    async function zone(value: string | null) {
      await db.query("select set_config('request.headers', $1, false)", [
        JSON.stringify(value ? { "x-sanju-study-time-zone": value } : {}),
      ]);
    }
    async function value(sql: string, args: any[] = []) {
      return Object.values((await db.query<any>(sql, args)).rows[0])[0];
    }
    async function reset() {
      await db.exec("truncate auth.users cascade");
      await db.query("select set_config('request.jwt.claim.sub', $1, false)", [
        owner,
      ]);
      await db.query("insert into auth.users values ($1)", [owner]);
      await db.query("insert into memories(id,user_id) values ($1,$2)", [
        memory,
        owner,
      ]);
      await db.query(
        "insert into study_scenes(id,user_id,name) values ($1,$2,'Test scene')",
        [scene, owner],
      );
      for (let index = 0; index < ids.length; index++) {
        await db.query(
          "insert into memory_sentences(id,memory_id,is_favorite,sort_order) values ($1,$2,true,$3)",
          [ids[index], memory, index],
        );
        await db.query(
          "insert into study_scene_sentences(scene_id,sentence_id,match_score) values ($1,$2,100)",
          [scene, ids[index]],
        );
      }
    }

    await t.step(
      "valid device zones are isolated and missing or invalid headers keep legacy behavior",
      async () => {
        for (
          const name of [
            "America/Los_Angeles",
            "Pacific/Kiritimati",
            "Europe/Berlin",
            "Asia/Shanghai",
            "UTC",
          ]
        ) {
          await zone(name);
          strictEqual(await value("select sentence_study_time_zone()"), name);
        }
        for (
          const name of [null, "Not/AZone", "UTC'; drop table auth.users; --"]
        ) {
          await zone(name);
          strictEqual(
            await value("select sentence_study_time_zone()"),
            "Asia/Shanghai",
          );
        }
        await db.query("select set_config('request.headers', $1, false)", [
          "not-json",
        ]);
        strictEqual(
          await value("select sentence_study_time_zone()"),
          "Asia/Shanghai",
        );
      },
    );

    for (
      const name of [
        "America/Los_Angeles",
        "Pacific/Kiritimati",
        "Asia/Shanghai",
      ]
    ) {
      await t.step(
        name + ": favorite and scene counts agree with queues across midnight",
        async () => {
          await reset();
          await zone(name);
          // One new, one due late today, one due tomorrow, and one already studied
          // today whose stored date came from a different device time zone.
          for (const scope of ["favorites", "scene:" + scene]) {
            for (
              const [index, offset, studiedToday] of [[1, 0, false], [
                2,
                1,
                false,
              ], [3, 0, true]] as const
            ) {
              await db.query(
                `
              insert into sentence_study_progress(user_id,sentence_id,study_scope,learning_step,correct_count,last_studied_on,last_studied_at,next_review_at)
              values ($1,$2,$3,1,1,
                (now() at time zone $4)::date - 1,
                case when $6 then now() else (((now() at time zone $4)::date - 3)::timestamp at time zone $4) end,
                (((now() at time zone $4)::date + $5::integer)::timestamp + interval '23 hours') at time zone $4)
            `,
                [owner, ids[index], scope, name, offset, studiedToday],
              );
            }
          }
          strictEqual(await value("select count_sentence_study_queue()"), 2);
          strictEqual(
            (await db.query("select * from get_sentence_study_queue(100)")).rows
              .length,
            2,
          );
          strictEqual(
            await value("select count_sentence_studied_today_reviewable()"),
            1,
          );
          strictEqual(
            (await db.query(
              "select * from get_sentence_studied_today_queue(100)",
            )).rows.length,
            1,
          );
          strictEqual(await value("select count_sentence_studied_today()"), 2);
          strictEqual(
            (await db.query("select * from get_study_scene_queue($1,100)", [
              scene,
            ])).rows.length,
            2,
          );
          strictEqual(
            (await db.query(
              "select * from get_studied_today_scene_queue($1,100)",
              [scene],
            )).rows.length,
            1,
          );
          const summary =
            (await db.query<any>("select * from get_study_scenes()")).rows[0];
          const owned = (await db.query<any>(
            "select * from get_study_scene_summary_for_owner($1,$2)",
            [owner, scene],
          )).rows[0];
          strictEqual(summary.due_count, 2);
          strictEqual(summary.reviewable_today_count, 1);
          deepStrictEqual(summary, owned);
        },
      );
    }

    await t.step(
      "changing device time zone reinterprets the actual study instant, not the stale date",
      async () => {
        await reset();
        await db.query(
          `
        insert into sentence_study_progress(user_id,sentence_id,study_scope,last_studied_at,last_studied_on,next_review_at)
        values ($1,$2,'favorites',
          (date_trunc('day', now() at time zone 'Pacific/Kiritimati') at time zone 'Pacific/Kiritimati') + interval '30 minutes',
          (now() at time zone 'Pacific/Kiritimati')::date,
          now() + interval '2 days')
      `,
          [owner, ids[0]],
        );
        for (const name of ["Pacific/Kiritimati", "America/Los_Angeles"]) {
          await zone(name);
          const expected = await value(
            "select count(*)::int from sentence_study_progress where (last_studied_at at time zone $1)::date = (now() at time zone $1)::date",
            [name],
          );
          strictEqual(
            await value("select count_sentence_studied_today_reviewable()"),
            expected,
          );
        }
      },
    );

    await t.step(
      "completion is once per local day and schedules the next local midnight",
      async () => {
        await reset();
        await zone("America/Los_Angeles");
        await db.query("select record_sentence_study_result($1,true)", [
          ids[0],
        ]);
        await db.query(
          "select record_sentence_study_result($1,true,'favorites')",
          [ids[0]],
        );
        strictEqual(
          await value(
            "select correct_count from sentence_study_progress where sentence_id=$1",
            [ids[0]],
          ),
          1,
        );
        strictEqual(
          await value(
            `
        select next_review_at = (((now() at time zone 'America/Los_Angeles')::date + 1)::timestamp at time zone 'America/Los_Angeles')
        from sentence_study_progress where sentence_id=$1
      `,
            [ids[0]],
          ),
          true,
        );
        // A date-only value from another zone must not allow a repeat completion.
        await db.query(
          "update sentence_study_progress set last_studied_on = last_studied_on - 1 where sentence_id=$1",
          [ids[0]],
        );
        await db.query(
          "select record_sentence_study_result($1,true,'favorites')",
          [ids[0]],
        );
        strictEqual(
          await value(
            "select correct_count from sentence_study_progress where sentence_id=$1",
            [ids[0]],
          ),
          1,
        );
        await db.query("select record_sentence_study_result($1,true,$2)", [
          ids[0],
          "scene:" + scene,
        ]);
        strictEqual(
          (await db.query(
            "select * from sentence_study_progress where sentence_id=$1",
            [ids[0]],
          )).rows.length,
          2,
        );
      },
    );

    await t.step(
      "daylight saving boundaries use local midnight rather than 24-hour durations",
      async () => {
        await zone("America/Los_Angeles");
        for (
          const [day, hours] of [["2026-03-08", 23], [
            "2026-11-01",
            25,
          ]] as const
        ) {
          strictEqual(
            Number(
              await value(
                `
          select extract(epoch from (
            (($1::date + 1)::timestamp at time zone sentence_study_time_zone()) -
            ($1::date::timestamp at time zone sentence_study_time_zone())
          )) / 3600
        `,
                [day],
              ),
            ),
            hours,
          );
        }
      },
    );

    await t.step(
      "anonymous progress merges using the device day and remains idempotent",
      async () => {
        await reset();
        await zone("America/Los_Angeles");
        const payload = [{
          sentence_id: ids[0],
          study_scope: "favorites",
          learning_step: 1,
          mastered_review_count: 0,
          correct_count: 1,
          wrong_count: 0,
          last_result: "correct",
          last_studied_at: "2026-09-21T02:30:00Z",
          last_studied_on: "2026-09-20",
          next_review_on: "2026-09-21",
        }];
        for (let index = 0; index < 2; index++) {
          await db.query(
            "select * from merge_local_sentence_study_progress($1::jsonb)",
            [JSON.stringify(payload)],
          );
        }
        const saved = (await db.query<any>(
          `select correct_count, last_studied_on::text as day,
        next_review_at = '2026-09-21T07:00:00Z'::timestamptz as local_midnight
        from sentence_study_progress`,
        )).rows[0];
        strictEqual(saved.correct_count, 1);
        strictEqual(saved.day, "2026-09-20");
        strictEqual(saved.local_midnight, true);
      },
    );

    await t.step("migration does not expose owner-only summaries", async () => {
      for (const role of ["anon", "authenticated"]) {
        strictEqual(
          await value(
            "select has_function_privilege($1,'get_study_scene_summary_for_owner(uuid,uuid)','EXECUTE')",
            [role],
          ),
          false,
        );
      }
      ok(
        await value(
          "select has_function_privilege('service_role','get_study_scene_summary_for_owner(uuid,uuid)','EXECUTE')",
        ),
      );
    });
  } finally {
    await db.close();
  }
});
