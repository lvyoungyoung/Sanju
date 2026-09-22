import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const migration = await Deno.readTextFile(
  new URL(
    "../../supabase/migrations/20260922001000_add_profile_speech_voice.sql",
    import.meta.url,
  ),
);

Deno.test("speech voice is optional, constrained, idempotent and preserves existing profile RLS", async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role authenticated;
      create table public.profiles (
        id text primary key, nickname text not null,
        english_level text default '简单', available_generations integer default 10
      );
      alter table public.profiles enable row level security;
      create policy own_profile on public.profiles to authenticated
        using (id = current_setting('test.user_id'))
        with check (id = current_setting('test.user_id'));
      grant select, insert, update on public.profiles to authenticated;
      insert into profiles(id,nickname) values ('alice','Alice'),('bob','Bob');
    `);
    await db.exec(migration);
    await db.exec(migration);
    await db.exec("set role authenticated; set test.user_id = 'alice';");
    strictEqual(
      (await db.query<{ speech_voice: string | null }>(
        "select speech_voice from profiles",
      )).rows[0].speech_voice,
      null,
    );
    for (const voice of ["Mia", "Chloe", "Milo", "Dean"]) {
      await db.query("update profiles set speech_voice=$1 where id='alice'", [
        voice,
      ]);
      strictEqual(
        (await db.query<{ speech_voice: string | null }>(
          "select speech_voice from profiles",
        )).rows[0].speech_voice,
        voice,
      );
    }
    await rejects(() => db.exec("update profiles set speech_voice='invalid'"));
    // Old clients omit the new field and keep their existing insert/update contracts.
    await db.exec(
      "update profiles set nickname='Renamed', english_level='高级' where id='alice'",
    );
    deepStrictEqual(
      (await db.query(
        "select speech_voice,available_generations from profiles",
      )).rows,
      [
        { speech_voice: "Dean", available_generations: 10 },
      ],
    );
    strictEqual(
      (await db.query(
        "update profiles set speech_voice='Mia' where id='bob' returning id",
      )).rows.length,
      0,
    );
    // Initial preference upload uses compare-and-set to avoid replacing another device's choice.
    strictEqual(
      (await db.query(
        "update profiles set speech_voice='Mia' where id='alice' and speech_voice is null returning id",
      )).rows.length,
      0,
    );
    await db.exec(
      "set test.user_id = 'new'; insert into profiles(id,nickname) values ('new','New')",
    );
    strictEqual(
      (await db.query<{ speech_voice: string | null }>(
        "select speech_voice from profiles",
      )).rows[0].speech_voice,
      null,
    );
  } finally {
    await db.close();
  }
});
