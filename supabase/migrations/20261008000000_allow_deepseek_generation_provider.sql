-- The original hosted schema restricts memories.provider to MiMo/Kimi.
-- Expand that allowlist without changing finalization or credit transactions.
do $$
declare
  target_table text;
  constraint_name text;
begin
  foreach target_table in array array['memories', 'guest_generation_jobs', 'generation_jobs'] loop
    constraint_name := target_table || '_provider_check';
    -- Some installations also constrain guest/job providers. Do not introduce
    -- a new restriction on those tables if they were previously unconstrained.
    if target_table = 'memories' or exists (
      select 1 from pg_constraint
      where conrelid = to_regclass('public.' || target_table)
        and conname = constraint_name and contype = 'c'
    ) then
      execute format('alter table public.%I drop constraint if exists %I', target_table, constraint_name);
      execute format(
        'alter table public.%I add constraint %I check (provider in (''mimo'', ''kimi'', ''deepseek''))',
        target_table, constraint_name
      );
    end if;
  end loop;
end;
$$;
