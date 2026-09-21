-- Extend the profile difficulty contract without changing existing values/defaults.
alter table public.profiles
  drop constraint if exists profiles_english_level_check;

alter table public.profiles
  add constraint profiles_english_level_check
  check (english_level in ('启蒙', '简单', '中等', '高级'));
