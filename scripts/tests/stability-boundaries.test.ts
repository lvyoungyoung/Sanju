// Offline regression tests run real handlers with fake service/Storage clients.
import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

async function loadHandler(name: string, prelude: string, exports = "") {
  const source = await Deno.readTextFile(
    new URL(`../../supabase/functions/${name}/index.ts`, import.meta.url),
  );
  return await import(
    "data:application/typescript," + encodeURIComponent(
      prelude + source.replace(/^import .*\n/gm, "") + exports,
    )
  );
}

const cleanup = await loadHandler(
  "cleanup-guest-generation-jobs",
  `
export let handler: (request: Request) => Promise<Response>;
export const state = { imageCalls: 0, deleteCalls: 0, loadCalls: 0, storageError: false, databaseError: false,
  jobs: [{ id: 'expired-guest-job', image_path: 'guest/photo.jpg' }], limit: 0, loadError: false,
  storageCount: 1, databaseCount: 1 };
const Deno = {
  env: { get: (name: string) => name.endsWith('URL') ? 'http://offline.invalid' : 'fake-service-key' },
  serve: (callback: typeof handler) => { handler = callback; }
};
function createClient() {
  const query = {
    lt: () => query, order: () => query,
    limit: async (limit: number) => { state.limit = limit; state.loadCalls++;
      return { data: state.jobs.slice(0, limit), error: state.loadError ? { message: 'load unavailable' } : null }; }
  };
  return {
    from: () => ({
      select: () => query,
      delete: () => ({ in: () => ({ select: async () => { state.deleteCalls++;
        return { data: Array.from({ length: state.databaseCount }, () => ({ id: 'expired-guest-job' })),
          error: state.databaseError ? { message: 'database unavailable' } : null }; } }) })
    }),
    storage: { from: () => ({ remove: async () => {
      state.imageCalls++;
      return { data: Array.from({ length: state.storageCount }, () => ({ name: 'photo.jpg' })),
        error: state.storageError ? { message: 'storage unavailable' } : null };
    } }) }
  };
}
`,
);

Deno.test("cleanup refuses GET and missing, user or incorrect credentials before accessing data", async () => {
  Object.assign(cleanup.state, {
    imageCalls: 0,
    deleteCalls: 0,
    storageError: false,
    databaseError: false,
    loadCalls: 0,
  });
  for (
    const [method, token, status] of [
      ["GET", "fake-service-key", 405],
      ["POST", "", 401],
      ["POST", "fake-user-jwt", 401],
      ["POST", "fake-service-key-extra", 401],
    ] as const
  ) {
    const response = await cleanup.handler(
      new Request("https://offline.invalid/cleanup", {
        method,
        headers: token ? { Authorization: `Bearer ${token}` } : {},
      }),
    );
    strictEqual(response.status, status);
  }
  strictEqual(cleanup.state.loadCalls, 0);
  strictEqual(cleanup.state.imageCalls, 0);
  strictEqual(cleanup.state.deleteCalls, 0);
});

function authorizedCleanup() {
  return cleanup.handler(
    new Request("https://offline.invalid/cleanup", {
      method: "POST",
      headers: { Authorization: "Bearer fake-service-key" },
    }),
  );
}

Deno.test("cleanup retains job records when Storage fails, then retries successfully", async () => {
  Object.assign(cleanup.state, {
    imageCalls: 0,
    deleteCalls: 0,
    storageError: true,
    databaseError: false,
  });
  const response = await authorizedCleanup();
  strictEqual(response.status, 500);
  strictEqual((await response.json()).success, false);
  strictEqual(cleanup.state.deleteCalls, 0);
  cleanup.state.storageError = false;
  const retry = await authorizedCleanup();
  strictEqual(retry.status, 200);
  deepStrictEqual(await retry.json(), {
    success: true,
    deletedJobs: 1,
    deletedImages: 1,
    hasMore: false,
  });
  strictEqual(cleanup.state.deleteCalls, 1);
});

Deno.test("cleanup reports a database failure and safely retries already removed images", async () => {
  Object.assign(cleanup.state, {
    imageCalls: 0,
    deleteCalls: 0,
    databaseError: true,
    storageError: false,
  });
  const response = await authorizedCleanup();
  strictEqual(response.status, 500);
  deepStrictEqual(await response.json(), {
    success: false,
    error: "Failed to delete guest jobs",
    details: "database unavailable",
    deletedJobs: 0,
    deletedImages: 1,
  });
  Object.assign(cleanup.state, { databaseError: false, storageCount: 0 });
  deepStrictEqual(await (await authorizedCleanup()).json(), {
    success: true,
    deletedJobs: 1,
    deletedImages: 0,
    hasMore: false,
  });
  cleanup.state.storageCount = 1;
});

Deno.test("cleanup is bounded, reports only confirmed deletion counts, and handles empty batches", async () => {
  const jobs = cleanup.state.jobs;
  cleanup.state.jobs = Array.from(
    { length: 101 },
    (_, i) => ({ id: `job-${i}`, image_path: null }),
  );
  Object.assign(cleanup.state, { imageCalls: 0, databaseCount: 98 });
  deepStrictEqual(await (await authorizedCleanup()).json(), {
    success: true,
    deletedJobs: 98,
    deletedImages: 0,
    hasMore: true,
  });
  strictEqual(cleanup.state.limit, 100);
  strictEqual(cleanup.state.imageCalls, 0);
  cleanup.state.jobs = [];
  deepStrictEqual(await (await authorizedCleanup()).json(), {
    success: true,
    deletedJobs: 0,
    deletedImages: 0,
    hasMore: false,
  });
  Object.assign(cleanup.state, {
    jobs,
    databaseCount: 1,
    loadError: true,
    imageCalls: 0,
    deleteCalls: 0,
  });
  strictEqual((await authorizedCleanup()).status, 500);
  strictEqual(cleanup.state.imageCalls, 0);
  strictEqual(cleanup.state.deleteCalls, 0);
  cleanup.state.loadError = false;
});

const owner = "10000000-0000-4000-8000-000000000001";
const migrationHandler = await loadHandler(
  "migrate-guest-credits",
  `
export let handler: (request: Request) => Promise<Response>;
export const state: { calls: Record<string, string>[], anonymous: boolean, refreshCalls: number, guestID: string } = {
  calls: [], anonymous: true, refreshCalls: 0, guestID: ${JSON.stringify(owner)}
};
const owner = ${JSON.stringify(owner)};
const Deno = {
  env: { get: (name: string) => name.endsWith('URL') ? 'http://offline.invalid' : 'placeholder' },
  serve: (callback: typeof handler) => { handler = callback; }
};
const fetch = async () => { state.refreshCalls++; return Response.json({ user: { id: state.guestID, is_anonymous: true } }); };
function createClient() {
  return {
    auth: { getUser: async () => ({ data: { user: { id: owner, is_anonymous: state.anonymous } }, error: null }) },
    from: () => ({ select: () => ({ eq: () => ({ single: async () => ({ data: { id: owner }, error: null }) }) }) }),
    rpc: async (_name: string, args: Record<string, string>) => {
      state.calls.push(args); return { data: [{ merged: true }], error: null };
    }
  };
}
`,
);

function migrate(guestUserID = owner) {
  return migrationHandler.handler(
    new Request("https://offline.invalid/migrate", {
      method: "POST",
      headers: { Authorization: "Bearer fake-test-token" },
      body: JSON.stringify({
        guestRefreshToken: "fake-refresh-token",
        guestUserID,
      }),
    }),
  );
}

Deno.test("credit migration rejects anonymous destinations and self-transfer without refreshing the guest", async () => {
  strictEqual((await migrate()).status, 403);
  migrationHandler.state.anonymous = false;
  strictEqual((await migrate()).status, 400);
  strictEqual(migrationHandler.state.refreshCalls, 0);
  deepStrictEqual(migrationHandler.state.calls, []);
});

Deno.test("credit migration permits a verified anonymous source into a different signed-in account", async () => {
  const guest = "20000000-0000-4000-8000-000000000002";
  Object.assign(migrationHandler.state, { anonymous: false, guestID: guest });
  strictEqual((await migrate(guest)).status, 200);
  deepStrictEqual(migrationHandler.state.calls, [{
    p_guest_user_id: guest,
    p_account_user_id: owner,
  }]);
});

Deno.test("real transfer SQL rejects self-transfer and null IDs without changing balance or ledger", async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create table profiles(id uuid primary key, available_generations integer not null);
      create table generation_transactions(user_id uuid, delta integer, balance_after integer, reason text, note text);
      create role anon; create role authenticated; create role service_role;
    `);
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../../supabase/migrations/20260415000000_migrate_guest_credits.sql",
          import.meta.url,
        ),
      ),
    );
    await db.exec(
      await Deno.readTextFile(
        new URL(
          "../../supabase/migrations/20260928000000_guard_guest_credit_transfer.sql",
          import.meta.url,
        ),
      ),
    );
    await db.query(
      "insert into profiles(id, available_generations) values ($1, 9)",
      [owner],
    );
    await rejects(
      () => db.query("select * from transfer_guest_credits($1, $1)", [owner]),
      /must be different/,
    );
    await rejects(
      () => db.query("select * from transfer_guest_credits(null, $1)", [owner]),
      /IDs are required/,
    );
    await rejects(
      () => db.query("select * from transfer_guest_credits($1, null)", [owner]),
      /IDs are required/,
    );
    const privileges = await db.query(
      "select has_function_privilege('authenticated', 'transfer_guest_credits(uuid,uuid)', 'EXECUTE') as allowed",
    );
    deepStrictEqual(privileges.rows, [{ allowed: false }]);
    const stored = await db.query(
      "select available_generations from profiles where id=$1",
      [owner],
    );
    deepStrictEqual(stored.rows, [{ available_generations: 9 }]);
    deepStrictEqual(
      (await db.query("select * from generation_transactions")).rows,
      [],
    );
  } finally {
    await db.close();
  }
});

const purchase = await loadHandler(
  "confirm-purchase",
  `
const Deno = { serve: () => {}, env: { get: () => undefined } };
const createClient: any = () => { throw new Error('Unexpected backend request'); };
const decodeJwt: any = () => { throw new Error('Unexpected Apple request'); };
const importPKCS8: any = () => { throw new Error('Unexpected signing'); };
const SignJWT: any = class {};
`,
  "\nexport { validateAppStoreTransactionPayload, validateOrphanedAnonymousPurchase, normalizePurchaseRPCResult };\n",
);

Deno.test("purchase validation rejects wrong owners, products, apps and revoked transactions", () => {
  const expected = {
    transactionID: "test-transaction",
    productID: "test-product",
    bundleID: "test-app",
    userID: owner,
  };
  const payload = {
    transactionId: expected.transactionID,
    productId: expected.productID,
    bundleId: expected.bundleID,
    appAccountToken: owner,
  };
  strictEqual(
    purchase.validateAppStoreTransactionPayload(payload, expected),
    null,
  );
  for (
    const mutation of [
      { transactionId: "wrong" },
      { productId: "wrong" },
      { bundleId: "wrong" },
      { appAccountToken: "wrong" },
      { appAccountToken: undefined },
      { revocationDate: Date.now() },
    ]
  ) {
    strictEqual(
      typeof purchase.validateAppStoreTransactionPayload({
        ...payload,
        ...mutation,
      }, expected),
      "string",
    );
  }
});

Deno.test("orphan discard cannot finish signed-in, current-owner or unverifiable purchases", async () => {
  const other = "20000000-0000-4000-8000-000000000002";
  const original = (anonymous: boolean) => ({
    auth: {
      admin: {
        getUserById: async () => ({
          data: { user: { is_anonymous: anonymous } },
          error: null,
        }),
      },
    },
  });
  const guest = { id: owner, is_anonymous: true };
  strictEqual(
    await purchase.validateOrphanedAnonymousPurchase(original(true), {
      appAccountToken: other,
    }, guest),
    null,
  );
  for (
    const [client, token, user] of [
      [original(false), other, guest],
      [original(true), owner, guest],
      [original(true), other, { id: owner, is_anonymous: false }],
      [original(true), undefined, guest],
      [
        {
          auth: {
            admin: {
              getUserById: async () => ({
                data: { user: null },
                error: { message: "offline" },
              }),
            },
          },
        },
        other,
        guest,
      ],
    ] as const
  ) {
    strictEqual(
      typeof await purchase.validateOrphanedAnonymousPurchase(client, {
        appAccountToken: token,
      }, user),
      "string",
    );
  }
});
