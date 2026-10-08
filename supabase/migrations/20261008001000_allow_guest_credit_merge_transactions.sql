-- transfer_guest_credits already uses merge_local for its atomic transfer ledger.
-- Replace the allowlist atomically, retaining all existing transaction reasons.
do $$
begin
    alter table public.generation_transactions
        drop constraint if exists generation_transactions_reason_check;
    alter table public.generation_transactions
        add constraint generation_transactions_reason_check
        check (reason in ('init', 'generate', 'purchase', 'admin_adjust', 'merge_local'));
end;
$$;
