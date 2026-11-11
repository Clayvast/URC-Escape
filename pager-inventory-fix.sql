-- Pager inventory improvements for URC Escape.
-- Run this after advanced-puzzle-setup.sql in the Supabase SQL Editor.
-- It lets a player open their Pager from inventory and select any Pager
-- challenge in a room they have discovered. The browser refreshes this list
-- automatically while the Pager panel is open.

create or replace function public.get_player_pager_puzzles()
returns table(id uuid, title text, room_name text, solved boolean)
language sql
stable
security definer
set search_path=public
as $$
  select
    p.id,
    p.title,
    p.room_name,
    exists(
      select 1
      from public.puzzle_solves s
      where s.puzzle_id=p.id and s.player_id=auth.uid()
    ) as solved
  from public.puzzles p
  where auth.uid() is not null
    and p.active=true
    and p.answer_type='pager'
    and exists(
      select 1
      from public.player_rooms r
      where r.player_id=auth.uid() and r.room_name=p.room_name
    )
  order by p.room_name, p.created_at, p.title;
$$;

revoke all on function public.get_player_pager_puzzles() from public, anon;
grant execute on function public.get_player_pager_puzzles() to authenticated;
