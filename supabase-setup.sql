-- Run in Supabase Dashboard -> SQL Editor.
create table if not exists public.profiles(id uuid primary key references auth.users(id) on delete cascade,username text unique not null,role text not null default 'player' check(role in ('player','admin')),starting_room text not null default 'Forum',ability text,created_at timestamptz default now());
create table if not exists public.player_rooms(player_id uuid references public.profiles(id) on delete cascade,room_name text not null,discovered_at timestamptz default now(),primary key(player_id,room_name));
create table if not exists public.player_progress(player_id uuid primary key references public.profiles(id) on delete cascade,xp integer not null default 0 check(xp>=0),key_shards integer not null default 0 check(key_shards>=0),updated_at timestamptz default now());
alter table public.profiles enable row level security; alter table public.player_rooms enable row level security; alter table public.player_progress enable row level security;
create or replace function public.is_urc_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;
create policy "profile self or admin read" on public.profiles for select to authenticated using(id=auth.uid() or public.is_urc_admin());
create policy "own rooms read" on public.player_rooms for select to authenticated using(player_id=auth.uid());
create policy "own rooms insert" on public.player_rooms for insert to authenticated with check(player_id=auth.uid());
create policy "own rooms update" on public.player_rooms for update to authenticated using(player_id=auth.uid()) with check(player_id=auth.uid());
create policy "own progress read" on public.player_progress for select to authenticated using(player_id=auth.uid());
create or replace function public.handle_urc_user() returns trigger language plpgsql security definer set search_path=public as $$ begin
insert into public.profiles(id,username,role,starting_room,ability) values(new.id,coalesce(new.raw_user_meta_data->>'username',split_part(new.email,'@',1)),coalesce(new.raw_app_meta_data->>'role','player'),coalesce(new.raw_user_meta_data->>'starting_room','Forum'),new.raw_user_meta_data->>'ability') on conflict(id) do nothing;
insert into public.player_progress(player_id) values(new.id) on conflict do nothing; return new; end; $$;
drop trigger if exists on_urc_auth_user_created on auth.users;
create trigger on_urc_auth_user_created after insert on auth.users for each row execute procedure public.handle_urc_user();
-- After creating your first admin Auth user, promote its profile:
-- update public.profiles set role='admin' where username='YOUR_ADMIN_USERNAME';
-- Browser policies intentionally do not allow players to award themselves XP or shards.
