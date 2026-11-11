-- Room unlocking system. Run after the base setup and puzzle migration.
create table if not exists public.room_unlock_rules (
  room_name text primary key,
  unlock_cost_shards integer not null default 0 check (unlock_cost_shards >= 0),
  required_room text,
  required_item_id text,
  active boolean not null default true
);
alter table public.room_unlock_rules enable row level security;
revoke all on public.room_unlock_rules from anon, authenticated;

-- Example progression. Adjust costs and prerequisites to suit the final game.
insert into public.room_unlock_rules(room_name,unlock_cost_shards,required_room,required_item_id) values
  ('Garden',1,'Hall',null),
  ('Kitchen',1,'Hall',null),
  ('Hall',2,'Hallway',null),
  ('Backstage',2,'Hall',null),
  ('Band Stand',1,'Stage',null),
  ('Stage',1,'Backstage',null),
  ('Sanctuary',1,'Forum',null),
  ('Hallway',1,'Forum',null),
  ('WC',1,'Hallway',null),
  ('Office (west)',1,'WC',null),
  ('Vestry',1,'Hallway',null),
  ('Lounge',1,'Vestry',null),
  ('Storage',2,'Hallway',null),
  ('Youth Room',2,'Hallway',null),
  ('Office (east)',1,'Youth Room',null),
  ('Side room',1,'Hallway',null)
on conflict(room_name) do nothing;

-- Ensure existing profiles have their starting room. Future users receive it
-- from the auth trigger below, so browsers cannot award themselves discoveries.
insert into public.player_rooms(player_id,room_name)
select id,starting_room from public.profiles
where starting_room is not null
on conflict(player_id,room_name) do nothing;

drop policy if exists "own rooms insert" on public.player_rooms;
drop policy if exists "own rooms update" on public.player_rooms;

create or replace function public.handle_urc_user()
returns trigger language plpgsql security definer set search_path=public
as $$
declare
  v_starting_room text;
begin
  v_starting_room := coalesce(new.raw_user_meta_data->>'starting_room','Forum');
  insert into public.profiles(id,username,role,starting_room,ability)
  values(
    new.id,
    coalesce(new.raw_user_meta_data->>'username',split_part(new.email,'@',1)),
    coalesce(new.raw_app_meta_data->>'role','player'),
    v_starting_room,
    new.raw_user_meta_data->>'ability'
  )
  on conflict(id) do nothing;

  insert into public.player_progress(player_id)
  values(new.id) on conflict do nothing;

  insert into public.player_rooms(player_id,room_name)
  values(new.id,v_starting_room) on conflict do nothing;
  return new;
end;
$$;

create or replace function public.get_room_unlock_options()
returns table(
  room_name text,
  unlock_cost_shards integer,
  required_room text,
  required_item_id text,
  unlocked boolean,
  has_required_room boolean,
  has_required_item boolean,
  current_shards integer,
  can_unlock boolean
)
language sql stable security definer set search_path=public
as $$
  select
    rules.room_name,
    rules.unlock_cost_shards,
    rules.required_room,
    rules.required_item_id,
    exists(select 1 from public.player_rooms pr where pr.player_id=auth.uid() and pr.room_name=rules.room_name),
    rules.required_room is null or exists(select 1 from public.player_rooms pr where pr.player_id=auth.uid() and pr.room_name=rules.required_room) or exists(select 1 from public.profiles p where p.id=auth.uid() and (p.starting_room=rules.required_room or rules.required_room='Forum')),
    rules.required_item_id is null or exists(select 1 from public.player_inventory pi where pi.player_id=auth.uid() and pi.item_id=rules.required_item_id and pi.quantity>0),
    coalesce(progress.key_shards,0),
    rules.active
      and not exists(select 1 from public.player_rooms pr where pr.player_id=auth.uid() and pr.room_name=rules.room_name)
      and (rules.required_room is null or exists(select 1 from public.player_rooms pr where pr.player_id=auth.uid() and pr.room_name=rules.required_room) or exists(select 1 from public.profiles p where p.id=auth.uid() and (p.starting_room=rules.required_room or rules.required_room='Forum')))
      and (rules.required_item_id is null or exists(select 1 from public.player_inventory pi where pi.player_id=auth.uid() and pi.item_id=rules.required_item_id and pi.quantity>0))
      and coalesce(progress.key_shards,0)>=rules.unlock_cost_shards
  from public.room_unlock_rules rules
  left join public.player_progress progress on progress.player_id=auth.uid()
  where auth.uid() is not null and rules.active
  order by rules.room_name;
$$;

create or replace function public.unlock_room(p_room_name text)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  v_rule public.room_unlock_rules%rowtype;
  v_shards integer;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to unlock a room.';
  end if;

  select * into v_rule
  from public.room_unlock_rules
  where room_name=p_room_name and active=true
  for share;

  if not found then
    return jsonb_build_object('success',false,'message','This room is not available to unlock.');
  end if;

  if exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=p_room_name) then
    return jsonb_build_object('success',true,'already_unlocked',true,'message','You have already discovered this room.');
  end if;

  if v_rule.required_room is not null
     and not exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=v_rule.required_room)
     and not exists(select 1 from public.profiles where id=auth.uid() and starting_room=v_rule.required_room) then
    return jsonb_build_object('success',false,'message','You must discover '||v_rule.required_room||' first.');
  end if;

  if v_rule.required_item_id is not null and not exists(
    select 1 from public.player_inventory where player_id=auth.uid() and item_id=v_rule.required_item_id and quantity>0
  ) then
    return jsonb_build_object('success',false,'message','You are missing the required item: '||v_rule.required_item_id||'.');
  end if;

  select key_shards into v_shards
  from public.player_progress where player_id=auth.uid()
  for update;

  if exists(select 1 from public.player_rooms where player_id=auth.uid() and room_name=p_room_name) then
    return jsonb_build_object('success',true,'already_unlocked',true,'message','You have already discovered this room.');
  end if;

  if coalesce(v_shards,0)<v_rule.unlock_cost_shards then
    return jsonb_build_object('success',false,'message','You need '||v_rule.unlock_cost_shards||' key shards to unlock this room.');
  end if;

  update public.player_progress
  set key_shards=key_shards-v_rule.unlock_cost_shards,updated_at=now()
  where player_id=auth.uid();

  insert into public.player_rooms(player_id,room_name)
  values(auth.uid(),p_room_name)
  on conflict(player_id,room_name) do nothing;

  return jsonb_build_object(
    'success',true,
    'already_unlocked',false,
    'message','Room unlocked!',
    'room_name',p_room_name,
    'shards_spent',v_rule.unlock_cost_shards,
    'shards_remaining',coalesce(v_shards,0)-v_rule.unlock_cost_shards
  );
end;
$$;

revoke all on function public.get_room_unlock_options() from public;
revoke all on function public.unlock_room(text) from public;
grant execute on function public.get_room_unlock_options() to authenticated;
grant execute on function public.unlock_room(text) to authenticated;
