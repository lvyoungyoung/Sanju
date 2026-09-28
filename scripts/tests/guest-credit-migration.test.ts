import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const migration = await Deno.readTextFile(
  new URL(
    "../../supabase/migrations/20260415000000_migrate_guest_credits.sql",
    import.meta.url,
  ),
);
const guest = "10000000-0000-0000-0000-000000000001";
const owner = "10000000-0000-0000-0000-000000000002";
const other = "10000000-0000-0000-0000-000000000003";

Deno.test("guest credit transfer preserves balance, ownership and atomic retry semantics", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create table profiles(id uuid primary key, available_generations integer not null);
      create table generation_transactions(user_id uuid, delta integer, balance_after integer, reason text, note text);
      create role anon; create role authenticated; create role service_role;
    `);
    await db.exec(migration);
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../../supabase/migrations/20260928000000_guard_guest_credit_transfer.sql",
          import.meta.url,
        ),
      ),
    );
    const transfer = (target = owner) =>
      db.query(
        "select * from transfer_guest_credits($1, $2)",
        [guest, target],
      );
    const reset = async (guestBalance = 9, accountBalance = 200) => {
      await db.exec("truncate profiles, generation_transactions");
      await db.query(
        "insert into profiles(id,available_generations) values($1,$2),($3,$4),($5,30)",
        [guest, guestBalance, owner, accountBalance, other],
      );
    };
    const balance = async (id: string) =>
      (await db.query<{ available_generations: number }>(
        "select available_generations from profiles where id=$1",
        [id],
      )).rows[0]?.available_generations;
    const ledger = async () =>
      (await db.query("select * from generation_transactions")).rows;

    await t.step(
      "existing account keeps purchases and receives only the guest remainder",
      async () => {
        await reset();
        deepStrictEqual((await transfer()).rows, [{
          available_generations: 209,
          merged: true,
        }]);
        strictEqual(await balance(guest), 0);
        strictEqual(await balance(owner), 209);
        strictEqual(await balance(other), 30);
        deepStrictEqual(await ledger(), [{
          user_id: owner,
          delta: 9,
          balance_after: 209,
          reason: "merge_local",
          note: `guest_user_id:${guest}`,
        }]);
      },
    );
    await t.step(
      "a new account gains no additional starter grant during transfer",
      async () => {
        await reset(9, 0);
        await transfer();
        strictEqual(await balance(owner), 9);
      },
    );
    await t.step(
      "repeated retries do not double-credit or duplicate the ledger",
      async () => {
        await reset();
        await transfer();
        for (let index = 0; index < 5; index++) {
          deepStrictEqual((await transfer()).rows, [{
            available_generations: 209,
            merged: false,
          }]);
        }
        strictEqual((await ledger()).length, 1);
      },
    );
    await t.step(
      "an exhausted guest is still marked migrated without a credit transaction",
      async () => {
        await reset(0);
        deepStrictEqual((await transfer()).rows, [{
          available_generations: 200,
          merged: false,
        }]);
        deepStrictEqual(await ledger(), []);
        const row = (await db.query<{ credits_merged_into_user_id: string }>(
          "select credits_merged_into_user_id from profiles where id=$1",
          [guest],
        )).rows[0];
        strictEqual(row.credits_merged_into_user_id, owner);
      },
    );
    await t.step(
      "the same guest cannot be credited to a second account",
      async () => {
        await reset();
        await transfer();
        await rejects(
          () => transfer(other),
          /already merged into another account/,
        );
        strictEqual(await balance(owner), 209);
        strictEqual(await balance(other), 30);
        strictEqual((await ledger()).length, 1);
      },
    );
    await t.step(
      "ledger write failure rolls back both balances and the migration marker",
      async () => {
        await reset();
        await db.exec(
          "alter table generation_transactions add constraint simulate_ledger_failure check (delta < 0)",
        );
        await rejects(() => transfer(), /simulate_ledger_failure/);
        strictEqual(await balance(guest), 9);
        strictEqual(await balance(owner), 200);
        const row =
          (await db.query<{ credits_merged_into_user_id: string | null }>(
            "select credits_merged_into_user_id from profiles where id=$1",
            [guest],
          )).rows[0];
        strictEqual(row.credits_merged_into_user_id, null);
        deepStrictEqual(await ledger(), []);
        await db.exec(
          "alter table generation_transactions drop constraint simulate_ledger_failure",
        );
        await transfer();
        strictEqual(await balance(owner), 209);
      },
    );
    await t.step("missing target cannot consume guest credits", async () => {
      await reset();
      await db.query("delete from profiles where id=$1", [owner]);
      await rejects(() => transfer(), /account profile not found/);
      strictEqual(await balance(guest), 9);
      deepStrictEqual(await ledger(), []);
    });
    await t.step(
      "missing guest is a no-op, not a new trial grant",
      async () => {
        await reset();
        await db.query("delete from profiles where id=$1", [guest]);
        deepStrictEqual((await transfer()).rows, [{
          available_generations: 200,
          merged: false,
        }]);
        deepStrictEqual(await ledger(), []);
      },
    );
  } finally {
    await db.close();
  }
});
