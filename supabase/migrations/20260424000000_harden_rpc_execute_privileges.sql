-- Harden RPC execution privileges.
--
-- Balance, purchase, generation, and guest-credit RPCs must only be callable
-- by trusted server-side code using the service role key. Client-facing study
-- RPCs are limited to authenticated users.

revoke all on function public.confirm_purchase_atomically(uuid, text, text, integer) from public;
revoke all on function public.confirm_purchase_atomically(uuid, text, text, integer) from anon;
revoke all on function public.confirm_purchase_atomically(uuid, text, text, integer) from authenticated;
grant execute on function public.confirm_purchase_atomically(uuid, text, text, integer) to service_role;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) to service_role;

revoke all on function public.transfer_guest_credits(uuid, uuid) from public;
revoke all on function public.transfer_guest_credits(uuid, uuid) from anon;
revoke all on function public.transfer_guest_credits(uuid, uuid) from authenticated;
grant execute on function public.transfer_guest_credits(uuid, uuid) to service_role;

revoke all on function public.try_acquire_generation_slot(uuid, uuid, integer, integer) from public;
revoke all on function public.try_acquire_generation_slot(uuid, uuid, integer, integer) from anon;
revoke all on function public.try_acquire_generation_slot(uuid, uuid, integer, integer) from authenticated;
grant execute on function public.try_acquire_generation_slot(uuid, uuid, integer, integer) to service_role;

revoke all on function public.release_generation_slot(uuid) from public;
revoke all on function public.release_generation_slot(uuid) from anon;
revoke all on function public.release_generation_slot(uuid) from authenticated;
grant execute on function public.release_generation_slot(uuid) to service_role;

revoke all on function public.get_sentence_study_queue(integer) from public;
revoke all on function public.get_sentence_study_queue(integer) from anon;
grant execute on function public.get_sentence_study_queue(integer) to authenticated;

revoke all on function public.count_sentence_study_queue() from public;
revoke all on function public.count_sentence_study_queue() from anon;
grant execute on function public.count_sentence_study_queue() to authenticated;

revoke all on function public.record_sentence_study_result(uuid, boolean) from public;
revoke all on function public.record_sentence_study_result(uuid, boolean) from anon;
grant execute on function public.record_sentence_study_result(uuid, boolean) to authenticated;
