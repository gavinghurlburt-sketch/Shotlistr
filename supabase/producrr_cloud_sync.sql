-- Producrr: per-user projects, track metadata, private audio bucket, account deletion

create table public.producrr_projects (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  id text not null,
  data jsonb not null default '{}'::jsonb,
  client_updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, id)
);

create table public.producrr_tracks (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key text not null,
  name text not null default '',
  size bigint not null default 0,
  mime text not null default '',
  updated_at timestamptz not null default now(),
  primary key (user_id, key)
);

alter table public.producrr_projects enable row level security;
alter table public.producrr_tracks enable row level security;

create policy "own projects select" on public.producrr_projects for select to authenticated using (user_id = (select auth.uid()));
create policy "own projects insert" on public.producrr_projects for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own projects update" on public.producrr_projects for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own projects delete" on public.producrr_projects for delete to authenticated using (user_id = (select auth.uid()));

create policy "own tracks select" on public.producrr_tracks for select to authenticated using (user_id = (select auth.uid()));
create policy "own tracks insert" on public.producrr_tracks for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own tracks update" on public.producrr_tracks for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own tracks delete" on public.producrr_tracks for delete to authenticated using (user_id = (select auth.uid()));

-- private bucket for audio tracks, files live under <user id>/
insert into storage.buckets (id, name, public, file_size_limit)
values ('tracks', 'tracks', false, 52428800)
on conflict (id) do nothing;

create policy "own track files select" on storage.objects for select to authenticated
  using (bucket_id = 'tracks' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own track files insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'tracks' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own track files update" on storage.objects for update to authenticated
  using (bucket_id = 'tracks' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'tracks' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "own track files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'tracks' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- in-app account deletion (App Store requirement). The client removes audio files first via the storage API.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
