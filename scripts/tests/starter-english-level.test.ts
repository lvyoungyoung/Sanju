import { ok, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
const source = await read("supabase/functions/generate-memory-v2/index.ts");
const promptFunction = source.match(/function buildPromptText\([\s\S]*?\n}/)
  ?.[0];
ok(promptFunction);
const { buildPromptText } = await import(
  "data:application/typescript," + encodeURIComponent(`
  type GenerationFormat = "legacy_v1" | "dual_tabs_v1";
  const LEARNING_TOPIC_PROMPT = "test topics";
  const LEARNING_TOPIC_CLASSIFICATION_GUIDANCE = "test boundaries";
  ${source.match(/^const EXPRESSION_PURPOSE_PROMPT = .*$/m)?.[0]}
  export ${promptFunction}
`)
);

Deno.test("starter overrides lyrical style in both generation formats", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"]) {
    const prompt = buildPromptText("启蒙", "抒情优美", format);
    strictEqual(prompt, buildPromptText("启蒙", "平铺直叙", format));
    ok(prompt.includes("3 到 6 个英文单词"));
    ok(prompt.includes("不要使用从句、抽象词、习语"));
    ok(prompt.includes("语言风格固定为平铺直叙"));
    ok(prompt.includes("3 到 15 个汉字"));
    ok(!prompt.includes("整体风格请明显更细腻"));
    if (format === "dual_tabs_v1") {
      ok(prompt.includes("启蒙的生活表达也必须使用 3 到 6 个单词"));
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

Deno.test("existing levels and lyrical style keep their generation rules", () => {
  for (
    const [level, length] of [["简单", "6 到 12"], ["中等", "10 到 18"], [
      "高级",
      "14 到 24",
    ]]
  ) {
    for (const format of ["legacy_v1", "dual_tabs_v1"]) {
      const prompt = buildPromptText(level, "抒情优美", format);
      ok(prompt.includes(length + " 个单词"));
      ok(prompt.includes("整体风格请明显更细腻"));
      ok(!prompt.includes("启蒙难度："));
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
