alter table public.profiles
add column if not exists credits_merged_into_user_id uuid;

alter table public.profiles
add column if not exists credits_merged_at timestamptz;

create or replace function public.transfer_guest_credits(
    p_guest_user_id uuid,
    p_account_user_id uuid
)
returns table (
    available_generations integer,
    merged boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
    guest_credits integer := 0;
    account_credits integer := 0;
    guest_merge_target uuid;
    new_balance integer := 0;
begin
    select profiles.available_generations
      into account_credits
      from public.profiles
     where profiles.id = p_account_user_id
     for update;

    if not found then
        raise exception 'account profile not found';
    end if;

    select
        profiles.available_generations,
        profiles.credits_merged_into_user_id
      into
        guest_credits,
        guest_merge_target
      from public.profiles
     where profiles.id = p_guest_user_id
     for update;

    if not found then
        return query
        select account_credits, false;
        return;
    end if;

    if guest_merge_target is not null then
        if guest_merge_target = p_account_user_id then
            return query
            select account_credits, false;
            return;
        end if;

        raise exception 'guest credits already merged into another account';
    end if;

    guest_credits := greatest(coalesce(guest_credits, 0), 0);
    new_balance := account_credits + guest_credits;

    update public.profiles
       set available_generations = new_balance
     where id = p_account_user_id;

    update public.profiles
       set available_generations = 0,
           credits_merged_into_user_id = p_account_user_id,
           credits_merged_at = timezone('utc', now())
     where id = p_guest_user_id;

    if guest_credits > 0 then
        insert into public.generation_transactions (
            user_id,
            delta,
            balance_after,
            reason,
            note
        )
        values (
            p_account_user_id,
            guest_credits,
            new_balance,
            'merge_local',
            'guest_user_id:' || p_guest_user_id::text
        );
    end if;

    return query
    select new_balance, guest_credits > 0;
end;
$$;
