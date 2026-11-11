-- Advanced interactive puzzle types for URC Escape.
-- Run once in Supabase SQL Editor AFTER admin-puzzle-setup.sql.

alter table public.puzzles
  add column if not exists puzzle_config jsonb not null default '{}'::jsonb;

alter table public.puzzles drop constraint if exists puzzles_answer_type_check;
alter table public.puzzles add constraint puzzles_answer_type_check check (
  answer_type in (
    'multiple_choice','text','numerical','cipher',
    'grid_sequence','pager','memory_sequence','combination_dials',
    'hidden_message','picture_reconstruction','circuit_connection',
    'maze','symbol_alignment'
  )
);

create table if not exists public.pager_codes (
  id uuid primary key default gen_random_uuid(),
  puzzle_id uuid not null references public.puzzles(id) on delete cascade,
  generated_by uuid not null references public.profiles(id) on delete cascade,
  code text not null,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists pager_codes_lookup_idx on public.pager_codes(puzzle_id,code,expires_at);
alter table public.pager_codes enable row level security;
revoke all on public.pager_codes from anon, authenticated;

create or replace function public.admin_list_puzzles()
returns table(
  id uuid, room_name text, title text, prompt text, answer_type text,
  options jsonb, answer text, numeric_tolerance numeric,
  hint_1 text, hint_2 text, hint_3 text,
  reward_xp integer, reward_shards integer, active boolean, puzzle_config jsonb
)
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_urc_admin() then raise exception 'Administrator access required.'; end if;
  return query
  select p.id,p.room_name,p.title,p.prompt,p.answer_type,p.options,p.answer,
    p.numeric_tolerance,coalesce(nullif(p.hint_1,''),p.hint),p.hint_2,p.hint_3,
    p.reward_xp,p.reward_shards,p.active,p.puzzle_config
  from public.puzzles p order by p.room_name,p.created_at,p.title;
end;
$$;

-- New signature includes p_config. Keep old overload removed to avoid ambiguity.
drop function if exists public.admin_save_puzzle(uuid,text,text,text,text,jsonb,text,numeric,text,text,text,integer,integer,boolean);
create or replace function public.admin_save_puzzle(
  p_id uuid,p_room_name text,p_title text,p_prompt text,p_answer_type text,
  p_options jsonb,p_answer text,p_numeric_tolerance numeric,
  p_hint_1 text,p_hint_2 text,p_hint_3 text,
  p_reward_xp integer,p_reward_shards integer,p_active boolean,p_config jsonb
)
returns uuid language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  if not public.is_urc_admin() then raise exception 'Administrator access required.'; end if;
  if p_room_name is null or p_room_name not in (
    'Garden','Kitchen','Hall','Backstage','Band Stand','Stage','Sanctuary','Forum',
    'Hallway','WC','Office (west)','Vestry','Lounge','Storage','Youth Room','Office (east)','Side room'
  ) then raise exception 'Choose a valid room.'; end if;
  if nullif(trim(p_title),'') is null or nullif(trim(p_prompt),'') is null then
    raise exception 'Puzzle title and instructions are required.';
  end if;
  if p_answer_type not in (
    'multiple_choice','text','numerical','cipher','grid_sequence','pager',
    'memory_sequence','combination_dials','hidden_message','picture_reconstruction',
    'circuit_connection','maze','symbol_alignment'
  ) then raise exception 'Unsupported puzzle type.'; end if;
  if p_answer_type not in ('pager') and nullif(trim(p_answer),'') is null then
    raise exception 'The correct answer/configured solution is required.';
  end if;
  if p_answer_type='multiple_choice' then
    if jsonb_typeof(coalesce(p_options,'[]'::jsonb)) <> 'array'
      or jsonb_array_length(coalesce(p_options,'[]'::jsonb)) < 2
      or not (coalesce(p_options,'[]'::jsonb) ? p_answer) then
      raise exception 'Multiple choice needs at least two options and the correct answer must match one.';
    end if;
  end if;
  if p_answer_type='numerical' then
    perform trim(p_answer)::numeric;
    if coalesce(p_numeric_tolerance,0)<0 then raise exception 'Tolerance cannot be negative.'; end if;
  end if;
  if p_id is null then
    insert into public.puzzles(room_name,title,prompt,hint,answer,reward_xp,reward_shards,active,
      answer_type,options,numeric_tolerance,hint_1,hint_2,hint_3,puzzle_config)
    values(p_room_name,trim(p_title),trim(p_prompt),coalesce(p_hint_1,''),coalesce(p_answer,''),
      greatest(coalesce(p_reward_xp,0),0),greatest(coalesce(p_reward_shards,0),0),coalesce(p_active,true),
      p_answer_type,coalesce(p_options,'[]'::jsonb),coalesce(p_numeric_tolerance,0),
      coalesce(p_hint_1,''),coalesce(p_hint_2,''),coalesce(p_hint_3,''),coalesce(p_config,'{}'::jsonb))
    returning id into v_id;
  else
    update public.puzzles set room_name=p_room_name,title=trim(p_title),prompt=trim(p_prompt),
      hint=coalesce(p_hint_1,''),answer=coalesce(p_answer,''),reward_xp=greatest(coalesce(p_reward_xp,0),0),
      reward_shards=greatest(coalesce(p_reward_shards,0),0),active=coalesce(p_active,true),
      answer_type=p_answer_type,options=coalesce(p_options,'[]'::jsonb),
      numeric_tolerance=coalesce(p_numeric_tolerance,0),hint_1=coalesce(p_hint_1,''),
      hint_2=coalesce(p_hint_2,''),hint_3=coalesce(p_hint_3,''),
      puzzle_config=coalesce(p_config,'{}'::jsonb)
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'Puzzle not found.'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.get_room_puzzles(p_room_name text)
returns table (
  id uuid,title text,prompt text,hint text,reward_xp integer,reward_shards integer,
  solved boolean,answer_type text,options jsonb,hint_1 text,hint_2 text,hint_3 text,
  numeric_tolerance numeric,puzzle_config jsonb
)
language sql stable security definer set search_path=public
as $$
  select p.id,p.title,p.prompt,p.hint,p.reward_xp,p.reward_shards,
    exists(select 1 from public.puzzle_solves s where s.puzzle_id=p.id and s.player_id=auth.uid()),
    p.answer_type,p.options,coalesce(nullif(p.hint_1,''),p.hint),p.hint_2,p.hint_3,
    p.numeric_tolerance,
    -- The solution is never returned. Only presentation/configuration fields are public.
    p.puzzle_config - 'solution' - 'correct' - 'answer' - 'sequence' - 'code'
  from public.puzzles p
  where auth.uid() is not null and p.active=true and p.room_name=p_room_name
    and exists(select 1 from public.player_rooms r where r.player_id=auth.uid() and r.room_name=p_room_name)
  order by p.created_at,p.title;
$$;

create or replace function public.create_pager_code(p_puzzle_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_puzzle public.puzzles%rowtype; v_code text;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  select * into v_puzzle from public.puzzles where id=p_puzzle_id and active=true and answer_type='pager';
  if not found then raise exception 'Pager puzzle not found.'; end if;
  if not exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=v_puzzle.room_name) then
    raise exception 'You must be in the puzzle room.'; end if;
  if not exists(select 1 from public.player_inventory where player_id=auth.uid() and item_id='pager' and quantity>0) then
    raise exception 'You need the Pager inventory item to generate a code.'; end if;
  v_code := lpad(floor(random()*1000000)::int::text,6,'0');
  insert into public.pager_codes(puzzle_id,generated_by,code,expires_at)
  values(p_puzzle_id,auth.uid(),v_code,now()+interval '2 minutes');
  return jsonb_build_object('code',v_code,'expires_at',now()+interval '2 minutes','message','Give this code to another player. It expires in 2 minutes.');
end;
$$;

create or replace function public.submit_puzzle_answer(p_puzzle_id uuid,p_answer text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_puzzle public.puzzles%rowtype;
  v_correct boolean := false;
  v_submitted numeric;
  v_expected numeric;
  v_code_id uuid;
begin
  if auth.uid() is null then raise exception 'You must be signed in to submit an answer.'; end if;
  select * into v_puzzle from public.puzzles where id=p_puzzle_id and active=true;
  if not found then return jsonb_build_object('correct',false,'message','This puzzle is no longer available.'); end if;
  if not exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=v_puzzle.room_name) then
    return jsonb_build_object('correct',false,'message','Discover this room before attempting its puzzle.'); end if;
  if exists(select 1 from public.puzzle_solves where player_id=auth.uid() and puzzle_id=p_puzzle_id) then
    return jsonb_build_object('correct',true,'already_solved',true,'message','You have already solved this puzzle.'); end if;

  if v_puzzle.answer_type='pager' then
    select id into v_code_id from public.pager_codes
    where puzzle_id=p_puzzle_id and code=trim(coalesce(p_answer,'')) and expires_at>now()
      and consumed_at is null and generated_by<>auth.uid()
    order by created_at desc limit 1 for update;
    if v_code_id is null then
      return jsonb_build_object('correct',false,'message','That code is invalid, expired, already used, or was generated by your own pager.');
    end if;
    update public.pager_codes set consumed_at=now() where id=v_code_id;
    v_correct:=true;
  elsif v_puzzle.answer_type='numerical' then
    begin
      v_submitted:=trim(coalesce(p_answer,''))::numeric; v_expected:=trim(v_puzzle.answer)::numeric;
      v_correct:=abs(v_submitted-v_expected)<=coalesce(v_puzzle.numeric_tolerance,0);
    exception when others then v_correct:=false; end;
  elsif v_puzzle.answer_type in ('grid_sequence','memory_sequence','combination_dials','picture_reconstruction','circuit_connection','maze','symbol_alignment') then
    begin
      v_correct := (p_answer::jsonb = v_puzzle.answer::jsonb);
    exception when others then v_correct:=false; end;
  elsif v_puzzle.answer_type='cipher' then
    v_correct:=regexp_replace(upper(coalesce(p_answer,'')),'[[:space:]]+','','g')=regexp_replace(upper(v_puzzle.answer),'[[:space:]]+','','g');
  else
    v_correct:=lower(regexp_replace(trim(coalesce(p_answer,'')),'[[:space:]]+',' ','g'))=lower(regexp_replace(trim(v_puzzle.answer),'[[:space:]]+',' ','g'));
  end if;
  if not v_correct then return jsonb_build_object('correct',false,'message','Not quite. Try again.'); end if;
  insert into public.puzzle_solves(player_id,puzzle_id) values(auth.uid(),p_puzzle_id) on conflict do nothing;
  update public.player_progress set xp=xp+v_puzzle.reward_xp,key_shards=key_shards+v_puzzle.reward_shards,updated_at=now()
  where player_id=auth.uid();
  return jsonb_build_object('correct',true,'already_solved',false,'message','Correct! Puzzle solved.',
    'xp_awarded',v_puzzle.reward_xp,'shards_awarded',v_puzzle.reward_shards);
end;
$$;

revoke all on function public.admin_list_puzzles() from public,anon;
revoke all on function public.admin_save_puzzle(uuid,text,text,text,text,jsonb,text,numeric,text,text,text,integer,integer,boolean,jsonb) from public,anon;
revoke all on function public.create_pager_code(uuid) from public,anon;
revoke all on function public.get_room_puzzles(text) from public;
revoke all on function public.submit_puzzle_answer(uuid,text) from public;
grant execute on function public.admin_list_puzzles() to authenticated;
grant execute on function public.admin_save_puzzle(uuid,text,text,text,text,jsonb,text,numeric,text,text,text,integer,integer,boolean,jsonb) to authenticated;
grant execute on function public.create_pager_code(uuid) to authenticated;
grant execute on function public.get_room_puzzles(text) to authenticated;
grant execute on function public.submit_puzzle_answer(uuid,text) to authenticated;
