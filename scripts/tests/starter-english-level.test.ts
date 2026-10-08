import { ok, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
import { buildPromptText } from "../../supabase/functions/generate-memory-v2/content.ts";

Deno.test("starter keeps natural child-safe speech in both generation formats", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
    const prompt = buildPromptText("启蒙", format);
    ok(prompt.includes("3 到 6 个英文单词"));
    ok(prompt.includes("不用从句、抽象词、习语"));
    ok(prompt.includes("友好自然直接"));
    ok(prompt.includes("3 到 15 个汉字"));
    ok(!prompt.includes("抒情优美：细腻温柔"));
    if (format === "dual_tabs_v1") {
      ok(prompt.includes("两组遵守同一档难度"));
      ok(
        prompt.includes(
          "image_descriptions 和 scene_and_feelings 都必须恰好有 3 项",
        ),
      );
    } else {
      ok(prompt.includes("sentences 必须是长度为 3 的数组"));
    }
  }
});

Deno.test("non-starter levels keep natural speech within their difficulty", () => {
  for (
    const [level, length] of [["简单", "6 到 10 个英文单词"], [
      "中等",
      "10 到 16 个英文单词",
    ], [
      "高级",
      "14 到 24 个单词",
    ]]
  ) {
    for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
      const prompt = buildPromptText(
        level as Parameters<typeof buildPromptText>[0],
        format,
      );
      ok(prompt.includes(length));
      ok(prompt.includes("自然的日常口语"));
      ok(!prompt.includes("启蒙："));
    }
  }
});

Deno.test("profile constraint accepts starter and preserves existing levels and defaults", async () => {
  const db = new PGlite();
  try {
    await db.exec(`create table profiles (
      id integer primary key,
      english_level text not null default '简单'
        constraint profiles_english_level_check check (english_level in ('简单','中等','高级'))
    ); insert into profiles(id) values (1);`);
    const migration = await read(
      "supabase/migrations/20260921001000_add_starter_english_level.sql",
    );
    await db.exec(migration);
    await db.exec(migration);
    for (const level of ["启蒙", "简单", "中等", "高级"]) {
      await db.query("update profiles set english_level=$1 where id=1", [
        level,
      ]);
      const result = await db.query<{ english_level: string }>(
        "select english_level from profiles where id=1",
      );
      strictEqual(result.rows[0].english_level, level);
    }
    await rejects(() => db.exec("update profiles set english_level='invalid'"));
    await db.exec("insert into profiles(id) values (2)");
    const result = await db.query<{ english_level: string }>(
      "select english_level from profiles where id=2",
    );
    strictEqual(result.rows[0].english_level, "简单");
  } finally {
    await db.close();
  }
});
