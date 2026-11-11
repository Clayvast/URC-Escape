-- Admin puzzle creator + four answer formats. Apply once after puzzle-setup.sql.
alter table public.puzzles
  add column if not exists answer_type text not null default 'text'
    check (answer_type in ('multiple_choice','text','numerical','cipher')),
  add column if not exists options jsonb not null default '[]'::jsonb,
  add column if not exists numeric_tolerance numeric not null default 0 check (numeric_tolerance >= 0),
  add column if not exists hint_1 text not null default '',
  add column if not exists hint_2 text not null default '',
  add column if not exists hint_3 text not null default '';

-- The admin editor is the only browser-facing route for puzzle management.
create or replace function public.admin_list_puzzles()
returns table(
  id uuid, room_name text, title text, prompt text, answer_type text,
  options jsonb, answer text, numeric_tolerance numeric,
  hint_1 text, hint_2 text, hint_3 text,
  reward_xp integer, reward_shards integer, active boolean
)
language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_urc_admin() then raise exception 'Administrator access required.'; end if;
  return query
  select p.id,p.room_name,p.title,p.prompt,p.answer_type,p.options,p.answer,
         p.numeric_tolerance,
         coalesce(nullif(p.hint_1,''),p.hint),
         p.hint_2,p.hint_3,p.reward_xp,p.reward_shards,p.active
  from public.puzzles p order by p.room_name,p.created_at,p.title;
end;
$$;

create or replace function public.admin_save_puzzle(
  p_id uuid,
  p_room_name text,
  p_title text,
  p_prompt text,
  p_answer_type text,
  p_options jsonb,
  p_answer text,
  p_numeric_tolerance numeric,
  p_hint_1 text,
  p_hint_2 text,
  p_hint_3 text,
  p_reward_xp integer,
  p_reward_shards integer,
  p_active boolean
)
returns uuid
language plpgsql security definer set search_path=public
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
  if p_answer_type not in ('multiple_choice','text','numerical','cipher') then
    raise exception 'Unsupported answer type.';
  end if;
  if nullif(trim(p_answer),'') is null then raise exception 'The correct answer is required.'; end if;
  if p_answer_type='multiple_choice' then
    if jsonb_typeof(coalesce(p_options,'[]'::jsonb)) <> 'array' then
      raise exception 'Multiple choice options must be a list.';
    end if;
    if jsonb_array_length(coalesce(p_options,'[]'::jsonb)) < 2
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
      answer_type,options,numeric_tolerance,hint_1,hint_2,hint_3)
    values(p_room_name,trim(p_title),trim(p_prompt),coalesce(p_hint_1,''),trim(p_answer),
      greatest(coalesce(p_reward_xp,0),0),greatest(coalesce(p_reward_shards,0),0),coalesce(p_active,true),
      p_answer_type,coalesce(p_options,'[]'::jsonb),coalesce(p_numeric_tolerance,0),
      coalesce(p_hint_1,''),coalesce(p_hint_2,''),coalesce(p_hint_3,'')) returning id into v_id;
  else
    update public.puzzles set room_name=p_room_name,title=trim(p_title),prompt=trim(p_prompt),
      hint=coalesce(p_hint_1,''),answer=trim(p_answer),
      reward_xp=greatest(coalesce(p_reward_xp,0),0),
      reward_shards=greatest(coalesce(p_reward_shards,0),0),
      active=coalesce(p_active,true),answer_type=p_answer_type,
      options=coalesce(p_options,'[]'::jsonb),
      numeric_tolerance=coalesce(p_numeric_tolerance,0),
      hint_1=coalesce(p_hint_1,''),hint_2=coalesce(p_hint_2,''),hint_3=coalesce(p_hint_3,'')
    where id=p_id returning id into v_id;
    if v_id is null then raise exception 'Puzzle not found.'; end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.admin_delete_puzzle(p_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
begin
  if not public.is_urc_admin() then raise exception 'Administrator access required.'; end if;
  delete from public.puzzles where id=p_id;
  return found;
end;
$$;

drop function if exists public.get_room_puzzles(text);
create function public.get_room_puzzles(p_room_name text)
returns table (
  id uuid, title text, prompt text, hint text, reward_xp integer,
  reward_shards integer, solved boolean, answer_type text, options jsonb,
  hint_1 text, hint_2 text, hint_3 text, numeric_tolerance numeric
)
language sql stable security definer set search_path=public
as $$
  select p.id,p.title,p.prompt,p.hint,p.reward_xp,p.reward_shards,
    exists(select 1 from public.puzzle_solves s where s.puzzle_id=p.id and s.player_id=auth.uid()),
    p.answer_type,p.options,
    coalesce(nullif(p.hint_1,''),p.hint),p.hint_2,p.hint_3,p.numeric_tolerance
  from public.puzzles p
  where auth.uid() is not null and p.active=true and p.room_name=p_room_name
    and exists(select 1 from public.player_rooms r where r.player_id=auth.uid() and r.room_name=p_room_name)
  order by p.created_at,p.title;
$$;

create or replace function public.submit_puzzle_answer(p_puzzle_id uuid,p_answer text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_puzzle public.puzzles%rowtype;
  v_correct boolean := false;
  v_submitted numeric;
  v_expected numeric;
begin
  if auth.uid() is null then raise exception 'You must be signed in to submit an answer.'; end if;
  select * into v_puzzle from public.puzzles where id=p_puzzle_id and active=true;
  if not found then return jsonb_build_object('correct',false,'message','This puzzle is no longer available.'); end if;
  if not exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=v_puzzle.room_name) then
    return jsonb_build_object('correct',false,'message','Discover this room before attempting its puzzle.');
  end if;
  if exists(select 1 from public.puzzle_solves where player_id=auth.uid() and puzzle_id=p_puzzle_id) then
    return jsonb_build_object('correct',true,'already_solved',true,'message','You have already solved this puzzle.');
  end if;

  if v_puzzle.answer_type='numerical' then
    begin
      v_submitted := trim(coalesce(p_answer,''))::numeric;
      v_expected := trim(v_puzzle.answer)::numeric;
      v_correct := abs(v_submitted-v_expected) <= coalesce(v_puzzle.numeric_tolerance,0);
    exception when others then v_correct := false;
    end;
  elsif v_puzzle.answer_type='cipher' then
    v_correct := regexp_replace(upper(coalesce(p_answer,'')),'[[:space:]]+','','g')
      = regexp_replace(upper(v_puzzle.answer),'[[:space:]]+','','g');
  else
    v_correct := lower(regexp_replace(trim(coalesce(p_answer,'')),'[[:space:]]+',' ','g'))
      = lower(regexp_replace(trim(v_puzzle.answer),'[[:space:]]+',' ','g'));
  end if;
  if not v_correct then return jsonb_build_object('correct',false,'message','Not quite. Try again.'); end if;

  insert into public.puzzle_solves(player_id,puzzle_id) values(auth.uid(),p_puzzle_id) on conflict do nothing;
  update public.player_progress set xp=xp+v_puzzle.reward_xp,
    key_shards=key_shards+v_puzzle.reward_shards,updated_at=now()
  where player_id=auth.uid();
  return jsonb_build_object('correct',true,'already_solved',false,'message','Correct! Puzzle solved.',
    'xp_awarded',v_puzzle.reward_xp,'shards_awarded',v_puzzle.reward_shards);
end;
$$;

revoke all on function public.admin_list_puzzles() from public,anon;
revoke all on function public.admin_save_puzzle(uuid,text,text,text,text,jsonb,text,numeric,text,text,text,integer,integer,boolean) from public,anon;
revoke all on function public.admin_delete_puzzle(uuid) from public,anon;
revoke all on function public.get_room_puzzles(text) from public;
revoke all on function public.submit_puzzle_answer(uuid,text) from public;
grant execute on function public.admin_list_puzzles() to authenticated;
grant execute on function public.admin_save_puzzle(uuid,text,text,text,text,jsonb,text,numeric,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.admin_delete_puzzle(uuid) to authenticated;
grant execute on function public.get_room_puzzles(text) to authenticated;
grant execute on function public.submit_puzzle_answer(uuid,text) to authenticated;
