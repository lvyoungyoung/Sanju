-- Protect profile balance fields from unsafe client-side writes.
--
-- Profiles remain client-readable and users may still update display/profile
-- preferences. Credit balance is server-owned for signed-in accounts, but
-- anonymous profiles need a narrow compatibility path so legitimate local
-- starter credits can still be prepared for guest-credit migration.

create or replace function public.protect_profile_balance_fields()
returns trigger
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  requester_role text := auth.role();
  is_anonymous boolean := coalesce(nullif(auth.jwt() ->> 'is_anonymous', '')::boolean, false);
  starter_credit_cap integer := 5;
begin
  -- Service-role Edge Functions and direct SQL maintenance remain trusted writers.
  if requester_role is null or requester_role = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.credits_merged_into_user_id := null;
    new.credits_merged_at := null;

    if is_anonymous then
      -- Anonymous profiles may receive the local starter/free balance so it can
      -- later be migrated to a signed-in account, but never more than the app's
      -- current starter grant.
      new.available_generations := least(
        greatest(coalesce(new.available_generations, starter_credit_cap), 0),
        starter_credit_cap
      );
    else
      -- Registered accounts should receive credits through purchase or guest
      -- migration flows, not by direct profile insert.
      new.available_generations := 0;
    end if;
  elsif tg_op = 'UPDATE' then
    if is_anonymous then
      -- Let the client lower an anonymous balance to match locally consumed
      -- starter credits, but never increase it. Paid credits and generated
      -- credits are handled by service-role Edge Functions.
      new.available_generations := least(
        greatest(coalesce(new.available_generations, old.available_generations), 0),
        old.available_generations
      );
    else
      new.available_generations := old.available_generations;
    end if;

    new.credits_merged_into_user_id := old.credits_merged_into_user_id;
    new.credits_merged_at := old.credits_merged_at;
  end if;

  return new;
end;
$$;

drop trigger if exists protect_profile_balance_fields_on_insert on public.profiles;
create trigger protect_profile_balance_fields_on_insert
before insert on public.profiles
for each row
execute function public.protect_profile_balance_fields();

drop trigger if exists protect_profile_balance_fields_on_update on public.profiles;
create trigger protect_profile_balance_fields_on_update
before update of available_generations, credits_merged_into_user_id, credits_merged_at
on public.profiles
for each row
execute function public.protect_profile_balance_fields();
