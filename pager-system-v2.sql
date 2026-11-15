-- URC Escape Pager v2: generate codes from inventory, redeem only in the matching puzzle.
-- Run in Supabase SQL Editor after pager-inventory-setup.sql and advanced-puzzle-setup.sql.

create table if not exists public.pager_codes (
  id uuid primary key default gen_random_uuid(),
  puzzle_id uuid not null references public.puzzles(id) on delete cascade,
  generated_by uuid not null references public.profiles(id) on delete cascade,
  code text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists pager_codes_lookup_idx
  on public.pager_codes(puzzle_id, code, expires_at);

-- The Pager can list every active Pager challenge, regardless of which room
-- the person holding the Pager has currently discovered.
create or replace function public.get_player_pager_puzzles()
returns table(id uuid, title text, room_name text, solved boolean)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.title, p.room_name,
    exists (
      select 1 from public.puzzle_solves s
      where s.puzzle_id = p.id and s.player_id = auth.uid()
    ) as solved
  from public.puzzles p
  where auth.uid() is not null
    and p.active = true
    and p.answer_type = 'pager'
  order by p.room_name, p.created_at, p.title;
$$;

-- A Pager owner chooses which challenge their code should unlock.
create or replace function public.create_pager_code(p_puzzle_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_puzzle public.puzzles%rowtype;
  v_code text;
  v_expires timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Sign in first.';
  end if;

  if not exists (
    select 1 from public.player_inventory
    where player_id = auth.uid() and item_id = 'pager' and quantity > 0
  ) then
    raise exception 'You need the Pager inventory item to generate a code.';
  end if;

  select * into v_puzzle
  from public.puzzles
  where id = p_puzzle_id and active = true and answer_type = 'pager';

  if not found then
    raise exception 'That Pager challenge is not active.';
  end if;

  -- Avoid duplicate live codes for the same challenge.
  loop
    v_code := lpad(floor(random() * 1000000)::int::text, 6, '0');
    exit when not exists (
      select 1 from public.pager_codes
      where puzzle_id = p_puzzle_id and code = v_code
        and expires_at > now() and consumed_at is null
    );
  end loop;

  v_expires := now() + interval '2 minutes';

  insert into public.pager_codes(puzzle_id, generated_by, code, expires_at)
  values (v_puzzle.id, auth.uid(), v_code, v_expires);

  return jsonb_build_object(
    'code', v_code,
    'expires_at', v_expires,
    'puzzle_id', v_puzzle.id,
    'puzzle_title', v_puzzle.title
  );
end;
$$;

-- The player must submit the code in the actual puzzle. The existing
-- submit_puzzle_answer(uuid,text) function validates puzzle_id, expiry,
-- single use, and that the redeemer is not the generator.
drop function if exists public.create_pager_code();

revoke all on function public.get_player_pager_puzzles() from public, anon;
revoke all on function public.create_pager_code(uuid) from public, anon;
grant execute on function public.get_player_pager_puzzles() to authenticated;
grant execute on function public.create_pager_code(uuid) to authenticated;

notify pgrst, 'reload schema';
