import { deepStrictEqual, strictEqual } from "node:assert";
import { readFunctionSource } from "./helpers/function-source.ts";
import { loadCompletedGuestGenerationResponseIfNeeded } from "../../supabase/functions/generate-memory-v2/repository.ts";

const source = await readFunctionSource(new URL(
  "../../supabase/functions/recover-guest-generation/index.ts", import.meta.url,
));
const harness = `
export let handler: (req: Request) => Promise<Response>;
export const state: any = { userID: '10000000-0000-4000-8000-000000000001', job: null };
const Deno = { env: {get: () => 'test'}, serve: (value: typeof handler) => {handler = value;} };
class Query {
  filters: Record<string, unknown> = {};
  patch: any;
  select(_: string) { return this; }
  update(value: any) { this.patch = value; return this; }
  eq(key: string, value: unknown) {
    this.filters[key] = value;
    if (this.patch && state.job?.id === value) Object.assign(state.job, this.patch);
    return this;
  }
  async maybeSingle() {
    const job = state.job;
    return {data: job && Object.entries(this.filters).every(([key,value]) => job[key] === value) ? job : null, error:null};
  }
}
export const client = {from: (_: string) => new Query(), auth: {getUser: async () => ({data:{user:{id:state.userID,is_anonymous:true}},error:null})}};
function createClient(..._: unknown[]) {return client;}
`;
const { handler, client, state } = await import(
  "data:application/typescript," + encodeURIComponent(harness + source)
);
const id = "10000000-0000-4000-8000-000000000002";
const sentences = Array.from({ length: 6 }, (_, i) => ({
  id: `20000000-0000-4000-8000-00000000000${i}`,
  english: `Sentence ${i}`, chinese: `Translation ${i}`,
  presentation_group: i < 3 ? "what_i_see" : "what_i_say", learning_topic_ids: [],
}));

Deno.test("guest generate replay and repeated recovery share a stable memory and sentence identity", async () => {
  state.job = { id, user_id: state.userID, status: "completed", sentences, tags: [],
    created_at: "2026-10-10T00:00:00Z", remaining_credits: 9, image_path: "test.jpg" };
  const request = () => new Request("https://test.invalid/recover", {
    method: "POST", headers: { Authorization: "Bearer test", "Content-Type": "application/json" },
    body: JSON.stringify({ guestJobID: id, generationFormat: "dual_tabs_v1" }),
  });
  const generated = await loadCompletedGuestGenerationResponseIfNeeded(client, {
    guestJobID: id, userID: state.userID, fallbackCreatedAt: state.job.created_at,
    fallbackRemainingCredits: 9, generationFormat: "dual_tabs_v1",
  });
  const first = await handler(request()), second = await handler(request());
  strictEqual(first.status, 200);
  strictEqual(second.status, 200);
  const initial = await generated!.json(), recovered = await first.json(), repeated = await second.json();
  strictEqual(initial.memory.id, id);
  strictEqual(recovered.memory.id, id);
  strictEqual(repeated.memory.id, id);
  deepStrictEqual(repeated.memory.sentences.map((s: any) => s.id), sentences.map(s => s.id));
  strictEqual(repeated.remainingCredits, 9);
  strictEqual(state.job.status, "acknowledged");
});

Deno.test("guest recovery remains owner scoped", async () => {
  state.job = { id, user_id: "someone-else", status: "completed", sentences };
  const result = await handler(new Request("https://test.invalid/recover", {
    method: "POST", headers: { Authorization: "Bearer test" }, body: JSON.stringify({ guestJobID: id }),
  }));
  strictEqual(result.status, 200);
  deepStrictEqual(await result.json(), { recovered: false });
});
