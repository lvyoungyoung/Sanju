alter table public.profiles
add column if not exists avatar_storage_path text;

alter table public.profiles
add column if not exists avatar_mime_type text;

alter table public.profiles
add column if not exists avatar_updated_at timestamptz;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'avatars',
  'avatars',
  false,
  2097152,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
