import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type CleanupJob = {
  id: string;
  lease_id: string;
  user_id: string;
  bucket_id: string;
  image_path: string;
};

export type MemoryImageCleanupResult = {
  claimed: number;
  completed: number;
  failed: number;
  hasMore: boolean;
};

const uuid =
  "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
const ownedImage = new RegExp(`^(${uuid})/${uuid}\\.jpg$`);

// Caller supplies a service-role client with a bounded transport. A failed
// acknowledgement leaves the lease recoverable; Storage remove is idempotent.
export async function consumeMemoryImageCleanup(
  client: SupabaseClient,
  limit = 10,
): Promise<MemoryImageCleanupResult> {
  const { data, error } = await client.rpc("claim_memory_image_cleanup_v2", {
    p_limit: limit,
  });
  if (error) throw new Error("Failed to claim memory image cleanup");
  if (!Array.isArray(data)) {
    throw new Error("Invalid memory image cleanup claims");
  }
  const jobs = data as CleanupJob[];
  const result = {
    claimed: jobs.length,
    completed: 0,
    failed: 0,
    hasMore: jobs.length === limit,
  };
  for (const job of jobs) {
    let failure: string | null = null;
    try {
      const pathOwner = typeof job.image_path === "string"
        ? job.image_path.match(ownedImage)?.[1]
        : undefined;
      if (
        job.bucket_id !== "memories" || !pathOwner || pathOwner !== job.user_id
      ) {
        failure = "invalid_image_path";
      } else {
        const authorization = await client.rpc(
          "authorize_memory_image_cleanup_v2",
          {
            p_job_id: job.id,
            p_lease_id: job.lease_id,
          },
        );
        if (authorization.error || authorization.data !== true) {
          failure = "image_cleanup_not_authorized";
        } else {
          const removed = await client.storage.from("memories").remove([
            job.image_path,
          ]);
          if (removed.error) failure = "storage_delete_failed";
        }
      }
    } catch {
      failure = "image_cleanup_transport_failed";
    }
    try {
      const finished = await client.rpc("finish_memory_image_cleanup_v2", {
        p_job_id: job.id,
        p_lease_id: job.lease_id,
        p_success: failure === null,
        p_error: failure,
      });
      if (finished.error || finished.data !== true) {
        failure = "image_cleanup_acknowledgement_failed";
      }
    } catch {
      failure = "image_cleanup_acknowledgement_failed";
    }
    if (failure) result.failed++;
    else result.completed++;
  }
  return result;
}
