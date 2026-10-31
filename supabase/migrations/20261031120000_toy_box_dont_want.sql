-- Game Night Minder: "I don't want to play this" option for The Toy Box.
-- A person can't tick both "want" and "don't want" for the same game.
-- Pick weight becomes: 1 + (confirmed guests who want it) - (confirmed guests who don't).
-- A game is skipped when that number is zero or less (more guests don't want it than want it).

alter table public.toybox_marks add column avoids boolean not null default false;
alter table public.toybox_marks add constraint toybox_marks_not_both check (not (wants and avoids));

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
      'wants',  (select count(*) from public.toybox_marks m join public.attendees a on a.id = m.attendee_id
                  where m.game_id = g.id and m.wants and a.active),
      'avoids', (select count(*) from public.toybox_marks m join public.attendees a on a.id = m.attendee_id
                  where m.game_id = g.id and m.avoids and a.active),
      'mine_owns',   coalesce((select m.owns   from public.toybox_marks m where m.game_id = g.id and m.attendee_id = v_att.id), false),
      'mine_wants',  coalesce((select m.wants  from public.toybox_marks m where m.game_id = g.id and m.attendee_id = v_att.id), false),
      'mine_avoids', coalesce((select m.avoids from public.toybox_marks m where m.game_id = g.id and m.attendee_id = v_att.id), false),
      'can_delete',  coalesce(g.added_by = v_att.id, false)) order by lower(g.title))
      from public.toybox_games g), '[]'::jsonb);
end $$;

drop function public.set_game_mark(text, uuid, boolean, boolean);
create function public.set_game_mark(p_token text, p_game_id uuid, p_owns boolean, p_wants boolean, p_avoids boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if not exists (select 1 from public.toybox_games where id = p_game_id) then raise exception 'not_found'; end if;
  if coalesce(p_wants, false) and coalesce(p_avoids, false) then raise exception 'invalid_marks'; end if;
  if not coalesce(p_owns, false) and not coalesce(p_wants, false) and not coalesce(p_avoids, false) then
    delete from public.toybox_marks where game_id = p_game_id and attendee_id = v_att.id;
  else
    insert into public.toybox_marks (game_id, attendee_id, owns, wants, avoids)
    values (p_game_id, v_att.id, coalesce(p_owns, false), coalesce(p_wants, false), coalesce(p_avoids, false))
    on conflict (game_id, attendee_id) do update set owns = excluded.owns, wants = excluded.wants, avoids = excluded.avoids;
  end if;
end $$;
revoke execute on function public.set_game_mark(text, uuid, boolean, boolean, boolean) from public;
grant  execute on function public.set_game_mark(text, uuid, boolean, boolean, boolean) to anon, authenticated;

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
    select g.id, w.weight
      from public.toybox_games g
     cross join lateral (select 1
        + (select count(*) from public.toybox_marks m join here h on h.attendee_id = m.attendee_id where m.game_id = g.id and m.wants)
        - (select count(*) from public.toybox_marks m join here h on h.attendee_id = m.attendee_id where m.game_id = g.id and m.avoids) as weight) w
     where w.weight > 0
       and exists (select 1 from public.toybox_marks o join here h on h.attendee_id = o.attendee_id
                    where o.game_id = g.id and o.owns)
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
