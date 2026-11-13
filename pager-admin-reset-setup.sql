-- URC Escape pager RPC + administrator progress reset.
-- Run once in Supabase SQL Editor AFTER advanced-puzzle-setup.sql.
-- This migration fixes the missing get_player_pager_puzzles() RPC and adds
-- an admin-only, atomic reset for all player accounts.

create or replace function public.get_player_pager_puzzles()
returns table(id uuid, title text, room_name text, solved boolean)
language sql
stable
security definer
set search_path = public
as $$
  select
    p.id,
    p.title,
    p.room_name,
    exists (
      select 1
      from public.puzzle_solves s
      where s.puzzle_id = p.id
        and s.player_id = auth.uid()
    ) as solved
  from public.puzzles p
  where auth.uid() is not null
    and p.active = true
    and p.answer_type = 'pager'
    and exists (
      select 1
      from public.player_rooms r
      where r.player_id = auth.uid()
        and r.room_name = p.room_name
    )
  order by p.room_name, p.created_at, p.title;
$$;

revoke all on function public.get_player_pager_puzzles() from public, anon;
grant execute on function public.get_player_pager_puzzles() to authenticated;


-- Resets every PLAYER while preserving accounts, usernames, passwords,
-- starting rooms, custom abilities, puzzle definitions and room rules.
-- Reset scope: XP, key shards, discovered rooms, solved puzzles, inventory,
-- and all outstanding Pager codes.
create or replace function public.admin_reset_all_player_progress()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_players integer;
  v_solves integer;
  v_inventory integer;
  v_rooms integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in.';
  end if;

  if not public.is_urc_admin() then
    raise exception 'Administrator access required.';
  end if;

  select count(*)::integer
  into v_players
  from public.profiles
  where role = 'player';

  -- Invalidate every outstanding Pager code.
  delete from public.pager_codes;

  delete from public.puzzle_solves
  where player_id in (
    select id from public.profiles where role = 'player'
  );
  get diagnostics v_solves = row_count;

  delete from public.player_inventory
  where player_id in (
    select id from public.profiles where role = 'player'
  );
  get diagnostics v_inventory = row_count;

  delete from public.player_rooms
  where player_id in (
    select id from public.profiles where role = 'player'
  );
  get diagnostics v_rooms = row_count;

  -- Restore each player to their configured starting room.
  insert into public.player_rooms(player_id, room_name)
  select id, starting_room
  from public.profiles
  where role = 'player'
  on conflict (player_id, room_name) do nothing;

  -- Reset scores, creating a progress row if one is unexpectedly missing.
  insert into public.player_progress(player_id, xp, key_shards, updated_at)
  select id, 0, 0, now()
  from public.profiles
  where role = 'player'
  on conflict (player_id) do update
    set xp = 0,
        key_shards = 0,
        updated_at = now();

  return jsonb_build_object(
    'success', true,
    'players_reset', v_players,
    'puzzle_solves_removed', v_solves,
    'inventory_rows_removed', v_inventory,
    'room_records_cleared', v_rooms,
    'message', 'All player progress has been reset.'
  );
end;
$$;

revoke all on function public.admin_reset_all_player_progress() from public, anon;
grant execute on function public.admin_reset_all_player_progress() to authenticated;


-- Ask PostgREST to refresh its function schema cache.
notify pgrst, 'reload schema';
