-- Game Night Minder: The Toy Box (shared game list) and automatic game pick

create table public.toybox_games (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (length(trim(title)) between 1 and 100),
  added_by   uuid references public.attendees(id) on delete set null,
  created_at timestamptz not null default now()
);
create unique index toybox_games_title_idx on public.toybox_games (lower(trim(title)));

-- One row per person per game: do they own it, do they want to play it
create table public.toybox_marks (
  game_id     uuid not null references public.toybox_games(id) on delete cascade,
  attendee_id uuid not null references public.attendees(id) on delete cascade,
  owns        boolean not null default false,
  wants       boolean not null default false,
  primary key (game_id, attendee_id)
);

-- Which game the system picked for which event (signup_id goes null if the entry is removed)
create table public.game_picks (
  id        uuid primary key default gen_random_uuid(),
  event_id  uuid not null references public.events(id) on delete cascade,
  game_id   uuid references public.toybox_games(id) on delete set null,
  owner_id  uuid references public.attendees(id) on delete set null,
  signup_id uuid references public.signups(id) on delete set null,
  rerolled  boolean not null default false,
  created_at timestamptz not null default now()
);
create index game_picks_event_idx on public.game_picks (event_id);

alter table public.toybox_games enable row level security;
alter table public.toybox_marks enable row level security;
alter table public.game_picks   enable row level security;
revoke all on public.toybox_games, public.toybox_marks, public.game_picks from anon, authenticated;
grant select, insert, update, delete on public.toybox_games, public.toybox_marks to authenticated;
grant select on public.game_picks to authenticated;
create policy admin_all  on public.toybox_games for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all  on public.toybox_marks for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_read on public.game_picks for select to authenticated using ((select public.is_admin()));

-- ---------- attendee functions (token based) ----------
create or replace function public.get_toybox(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id, 'title', g.title,
      'owners', coalesce((select jsonb_agg(a.name order by a.name) from public.toybox_marks m
                           join public.attendees a on a.id = m.attendee_id
                          where m.game_id = g.id and m.owns and a.active), '[]'::jsonb),
      'wants', (select count(*) from public.toybox_marks m join public.attendees a on a.id = m.attendee_id
                 where m.game_id = g.id and m.wants and a.active),
      'mine_owns',  coalesce((select m.owns  from public.toybox_marks m where m.game_id = g.id and m.attendee_id = v_att.id), false),
      'mine_wants', coalesce((select m.wants from public.toybox_marks m where m.game_id = g.id and m.attendee_id = v_att.id), false),
      'can_delete', coalesce(g.added_by = v_att.id, false)) order by lower(g.title))
      from public.toybox_games g), '[]'::jsonb);
end $$;

-- Adding a game also ticks "I want to play this!" for the person who added it
create or replace function public.add_game(p_token text, p_title text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype; v_title text := regexp_replace(trim(coalesce(p_title, '')), '\s+', ' ', 'g'); v_id uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if length(v_title) < 1 or length(v_title) > 100 then raise exception 'invalid_title'; end if;
  begin
    insert into public.toybox_games (title, added_by) values (v_title, v_att.id) returning id into v_id;
  exception when unique_violation then raise exception 'game_exists';
  end;
  insert into public.toybox_marks (game_id, attendee_id, wants) values (v_id, v_att.id, true);
  return v_id;
end $$;

create or replace function public.set_game_mark(p_token text, p_game_id uuid, p_owns boolean, p_wants boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if not exists (select 1 from public.toybox_games where id = p_game_id) then raise exception 'not_found'; end if;
  if not coalesce(p_owns, false) and not coalesce(p_wants, false) then
    delete from public.toybox_marks where game_id = p_game_id and attendee_id = v_att.id;
  else
    insert into public.toybox_marks (game_id, attendee_id, owns, wants)
    values (p_game_id, v_att.id, coalesce(p_owns, false), coalesce(p_wants, false))
    on conflict (game_id, attendee_id) do update set owns = excluded.owns, wants = excluded.wants;
  end if;
end $$;

-- Only the person who added a game can remove it (the organizer can remove any, from the admin page)
create or replace function public.delete_game(p_token text, p_game_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  delete from public.toybox_games where id = p_game_id and added_by = v_att.id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- ---------- the pick ----------
-- Candidates: games owned by at least one confirmed guest (status yes), not already picked for this event.
-- Weighted random choice: weight = 1 + number of confirmed guests who ticked "I want to play this!".
-- Owner: the host if the host owns it, otherwise a random confirmed owner.
-- The pick appears as a Games entry for that owner. p_reroll replaces the current pick (kept if nothing else qualifies).
create or replace function public.pick_game(p_event_id uuid, p_reroll boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_event  public.events%rowtype;
  v_host   uuid;
  v_game   public.toybox_games%rowtype;
  v_owner  uuid;
  v_signup uuid;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'event_not_found'; end if;
  if v_event.status <> 'scheduled' then raise exception 'not_scheduled'; end if;

  if not p_reroll and exists (select 1 from public.game_picks where event_id = p_event_id and signup_id is not null) then
    return jsonb_build_object('status', 'already_picked');
  end if;

  select attendee_id into v_host from public.signups where event_id = p_event_id and role = 'host' limit 1;

  with here as (
    select i.attendee_id from public.invitations i join public.attendees a on a.id = i.attendee_id
     where i.event_id = p_event_id and i.status = 'yes' and a.active),
  cand as (
    select g.id,
           1 + (select count(*) from public.toybox_marks w join here h on h.attendee_id = w.attendee_id
                 where w.game_id = g.id and w.wants) as weight
      from public.toybox_games g
     where exists (select 1 from public.toybox_marks o join here h on h.attendee_id = o.attendee_id
                    where o.game_id = g.id and o.owns)
       -- skip games already picked, rerolled, or whose entry was removed by an owner who is still coming;
       -- a game whose owner declined can be picked again (with another owner)
       and not exists (select 1 from public.game_picks gp
                        where gp.event_id = p_event_id and gp.game_id = g.id
                          and (gp.signup_id is not null or gp.rerolled
                               or exists (select 1 from here h where h.attendee_id = gp.owner_id))))
  select g.* into v_game from cand join public.toybox_games g on g.id = cand.id
   order by -ln(1 - random()) / cand.weight limit 1;
  if not found then return jsonb_build_object('status', 'no_candidates'); end if;

  select o.attendee_id into v_owner
    from public.toybox_marks o
    join public.invitations i on i.attendee_id = o.attendee_id and i.event_id = p_event_id and i.status = 'yes'
    join public.attendees a on a.id = o.attendee_id and a.active
   where o.game_id = v_game.id and o.owns
   order by (o.attendee_id = v_host) desc nulls last, random() limit 1;

  -- Re-pick: only now that a replacement exists, drop the current entry (its game stays excluded)
  if p_reroll then
    update public.game_picks set rerolled = true where event_id = p_event_id and signup_id is not null;
    delete from public.signups
     where id in (select signup_id from public.game_picks where event_id = p_event_id and signup_id is not null);
  end if;

  insert into public.signups (event_id, attendee_id, role, details)
  values (p_event_id, v_owner, 'game', left(v_game.title, 150) || ' (picked from The Toy Box)')
  returning id into v_signup;
  insert into public.game_picks (event_id, game_id, owner_id, signup_id)
  values (p_event_id, v_game.id, v_owner, v_signup);

  return jsonb_build_object('status', 'picked', 'title', v_game.title, 'owner_id', v_owner,
                            'owner', (select name from public.attendees where id = v_owner));
end $$;

create or replace function public.admin_pick_game(p_event_id uuid, p_reroll boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return public.pick_game(p_event_id, p_reroll);
end $$;

-- ---------- permissions ----------
revoke execute on function public.get_toybox(text), public.add_game(text, text),
  public.set_game_mark(text, uuid, boolean, boolean), public.delete_game(text, uuid) from public;
grant  execute on function public.get_toybox(text), public.add_game(text, text),
  public.set_game_mark(text, uuid, boolean, boolean), public.delete_game(text, uuid) to anon, authenticated;
revoke execute on function public.pick_game(uuid, boolean) from public, anon, authenticated;
grant  execute on function public.pick_game(uuid, boolean) to service_role;
revoke execute on function public.admin_pick_game(uuid, boolean) from public, anon;
grant  execute on function public.admin_pick_game(uuid, boolean) to authenticated;
