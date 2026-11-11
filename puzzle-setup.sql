-- Apply this migration once in Supabase SQL Editor after the base setup.
-- Puzzle system. Puzzle answers are kept in a table that players cannot read
-- directly; the RPCs expose prompts and validate answers on the server.
create table if not exists public.puzzles (
  id uuid primary key default gen_random_uuid(),
  room_name text not null,
  title text not null,
  prompt text not null,
  hint text not null default '',
  answer text not null,
  reward_xp integer not null default 25 check (reward_xp >= 0),
  reward_shards integer not null default 0 check (reward_shards >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.puzzles enable row level security;
revoke all on public.puzzles from anon, authenticated;

create table if not exists public.puzzle_solves (
  player_id uuid not null references public.profiles(id) on delete cascade,
  puzzle_id uuid not null references public.puzzles(id) on delete cascade,
  solved_at timestamptz not null default now(),
  primary key (player_id, puzzle_id)
);
alter table public.puzzle_solves enable row level security;
revoke all on public.puzzle_solves from anon, authenticated;

create or replace function public.get_room_puzzles(p_room_name text)
returns table (
  id uuid,
  title text,
  prompt text,
  hint text,
  reward_xp integer,
  reward_shards integer,
  solved boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.title, p.prompt, p.hint, p.reward_xp, p.reward_shards,
         exists (
           select 1 from public.puzzle_solves s
           where s.puzzle_id = p.id and s.player_id = auth.uid()
         ) as solved
  from public.puzzles p
  where auth.uid() is not null
    and p.active = true
    and p.room_name = p_room_name
    and exists (
      select 1 from public.player_rooms r
      where r.player_id = auth.uid() and r.room_name = p_room_name
    )
  order by p.created_at, p.title;
$$;

create or replace function public.submit_puzzle_answer(p_puzzle_id uuid, p_answer text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_puzzle public.puzzles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to submit an answer.';
  end if;

  select * into v_puzzle
  from public.puzzles
  where id = p_puzzle_id and active = true;

  if not found then
    return jsonb_build_object('correct', false, 'message', 'This puzzle is no longer available.');
  end if;

  if not exists (
    select 1 from public.player_rooms
    where player_id = auth.uid() and room_name = v_puzzle.room_name
  ) then
    return jsonb_build_object('correct', false, 'message', 'Discover this room before attempting its puzzle.');
  end if;

  if exists (
    select 1 from public.puzzle_solves
    where player_id = auth.uid() and puzzle_id = p_puzzle_id
  ) then
    return jsonb_build_object('correct', true, 'already_solved', true, 'message', 'You have already solved this puzzle.');
  end if;

  if lower(regexp_replace(trim(coalesce(p_answer, '')), '\\s+', ' ', 'g'))
     <> lower(regexp_replace(trim(v_puzzle.answer), '\\s+', ' ', 'g')) then
    return jsonb_build_object('correct', false, 'message', 'Not quite. Try again.');
  end if;

  insert into public.puzzle_solves(player_id, puzzle_id)
  values (auth.uid(), p_puzzle_id)
  on conflict do nothing;

  update public.player_progress
  set xp = xp + v_puzzle.reward_xp,
      key_shards = key_shards + v_puzzle.reward_shards,
      updated_at = now()
  where player_id = auth.uid();

  return jsonb_build_object(
    'correct', true,
    'already_solved', false,
    'message', 'Correct! Puzzle solved.',
    'xp_awarded', v_puzzle.reward_xp,
    'shards_awarded', v_puzzle.reward_shards
  );
end;
$$;

revoke all on function public.get_room_puzzles(text) from public;
revoke all on function public.submit_puzzle_answer(uuid, text) from public;
grant execute on function public.get_room_puzzles(text) to authenticated;
grant execute on function public.submit_puzzle_answer(uuid, text) to authenticated;
