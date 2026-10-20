-- Older shipped clients explicitly select this field while loading both tabs.
-- Keep an empty compatibility field after retiring sentence classification.
begin;
set local lock_timeout = '5s';

alter table public.memory_sentences
  add column if not exists learning_topic_ids text[] not null default '{}'::text[];

comment on column public.memory_sentences.learning_topic_ids is
  'Legacy client compatibility only. Sentence classification is retired; new rows default to an empty array.';

notify pgrst, 'reload schema';
commit;
