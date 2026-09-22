-- Nullable means the account has not saved a voice yet. Existing clients can
-- keep inserting/updating profiles without sending this optional preference.
alter table public.profiles
  add column if not exists speech_voice text
  constraint profiles_speech_voice_check
  check (speech_voice in ('Mia', 'Chloe', 'Milo', 'Dean'));

comment on column public.profiles.speech_voice is
  'Account reading voice. Null until first configured; governed by existing profile RLS.';

notify pgrst, 'reload schema';
