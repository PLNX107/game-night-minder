-- Game Night Minder: functions attendees use through their private link.
-- Each takes the attendee's token. All are SECURITY DEFINER with a fixed
-- search_path. Errors are short codes the web pages can translate.

-- Internal helper: the event the pages currently work on (latest non-cancelled month)
create or replace function public._current_event_id()
returns uuid
language sql stable security definer
set search_path = public
as $$
  select id from public.events where status <> 'cancelled' order by month desc limit 1
$$;

-- Internal: the ONLY way ballots are written. Requires an explicit yes/no for
-- every date option of the event, no more and no fewer.
create or replace function public._write_ballot(
  p_attendee_id uuid, p_event_id uuid, p_answers jsonb, p_force boolean default false
)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_status   text;
  v_expected int;
  v_keys     int;
  v_matched  int;
  v_ballot   uuid;
begin
  select status into v_status from public.events where id = p_event_id;
  if v_status is null then raise exception 'event_not_found'; end if;
  if v_status = 'cancelled' or (v_status <> 'polling' and not p_force) then
    raise exception 'poll_closed';
  end if;
  if jsonb_typeof(p_answers) is distinct from 'object' then raise exception 'invalid_ballot'; end if;

  select count(*) into v_expected from public.date_options where event_id = p_event_id;
  if v_expected = 0 then raise exception 'no_options'; end if;

  select count(*) into v_keys from jsonb_object_keys(p_answers);
  select count(*) into v_matched
    from jsonb_each(p_answers) e
    join public.date_options o on o.id::text = e.key and o.event_id = p_event_id
   where jsonb_typeof(e.value) = 'boolean';
  if v_keys <> v_expected or v_matched <> v_expected then raise exception 'incomplete_ballot'; end if;

  insert into public.ballots (event_id, attendee_id) values (p_event_id, p_attendee_id)
  on conflict (event_id, attendee_id) do update set updated_at = now()
  returning id into v_ballot;

  delete from public.votes where ballot_id = v_ballot;
  insert into public.votes (ballot_id, option_id, available)
  select v_ballot, o.id, (e.value)::boolean
    from jsonb_each(p_answers) e
    join public.date_options o on o.id::text = e.key and o.event_id = p_event_id;
end
$$;

-- Vote page: who am I, what is the poll, what did I answer before
create or replace function public.get_poll(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_att   public.attendees%rowtype;
  v_event public.events%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;

  select * into v_event from public.events where id = public._current_event_id();
  if not found then
    return jsonb_build_object('attendee', jsonb_build_object('name', v_att.name), 'event', null);
  end if;

  return jsonb_build_object(
    'attendee', jsonb_build_object('name', v_att.name),
    'event', jsonb_build_object(
      'month', v_event.month, 'status', v_event.status,
      'poll_closes_at', v_event.poll_closes_at, 'chosen_date', v_event.chosen_date),
    'has_submitted', exists (
      select 1 from public.ballots where event_id = v_event.id and attendee_id = v_att.id),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', o.id, 'date', o.option_date, 'available', v.available)
             order by o.option_date)
        from public.date_options o
        left join public.ballots b on b.event_id = o.event_id and b.attendee_id = v_att.id
        left join public.votes v on v.ballot_id = b.id and v.option_id = o.id
       where o.event_id = v_event.id), '[]'::jsonb)
  );
end
$$;

-- p_answers example: {"<option uuid>": true, "<option uuid>": false, ...}
create or replace function public.submit_ballot(p_token text, p_answers jsonb)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  perform public._write_ballot(v_att.id, public._current_event_id(), p_answers, false);
end
$$;

-- Volunteer page: event details, my invitation status, everyone's sign-ups
create or replace function public.get_event_board(p_token text)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_att   public.attendees%rowtype;
  v_event public.events%rowtype;
  v_inv   public.invitations%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;

  select * into v_event from public.events
   where id = public._current_event_id() and status = 'scheduled';
  if not found then
    return jsonb_build_object('attendee', jsonb_build_object('name', v_att.name), 'event', null);
  end if;

  select * into v_inv from public.invitations
   where event_id = v_event.id and attendee_id = v_att.id;

  return jsonb_build_object(
    'attendee', jsonb_build_object('name', v_att.name),
    'invitation_status', v_inv.status,   -- null if never invited
    'event', jsonb_build_object(
      'chosen_date', v_event.chosen_date, 'start_time', v_event.start_time,
      'notes', v_event.notes,
      'location', case when v_inv.status = 'invited' then v_event.location end),
    'signups', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id, 'role', s.role, 'details', s.details,
               'name', a.name, 'mine', s.attendee_id = v_att.id)
             order by s.created_at)
        from public.signups s join public.attendees a on a.id = s.attendee_id
       where s.event_id = v_event.id), '[]'::jsonb)
  );
end
$$;

create or replace function public.add_signup(p_token text, p_role text, p_details text default '')
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  v_att   public.attendees%rowtype;
  v_event uuid;
  v_id    uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if p_role not in ('host', 'food', 'beverage', 'game') then raise exception 'invalid_role'; end if;

  select id into v_event from public.events
   where id = public._current_event_id() and status = 'scheduled';
  if v_event is null then raise exception 'not_scheduled'; end if;

  if not exists (select 1 from public.invitations
                  where event_id = v_event and attendee_id = v_att.id and status = 'invited') then
    raise exception 'not_invited';
  end if;

  begin
    insert into public.signups (event_id, attendee_id, role, details)
    values (v_event, v_att.id, p_role, left(coalesce(p_details, ''), 200))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'host_taken';
  end;
  return v_id;
end
$$;

create or replace function public.remove_signup(p_token text, p_signup_id uuid)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;

  delete from public.signups
   where id = p_signup_id and attendee_id = v_att.id
     and event_id = public._current_event_id();
  if not found then raise exception 'not_found'; end if;
end
$$;

-- "Can't make it" / "Actually I can come" link. Declining frees up any roles.
create or replace function public.set_invitation_status(p_token text, p_status text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_att   public.attendees%rowtype;
  v_event uuid;
begin
  if p_status not in ('invited', 'declined') then raise exception 'invalid_status'; end if;
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;

  v_event := public._current_event_id();
  update public.invitations
     set status = p_status,
         declined_at = case when p_status = 'declined' then now() else null end
   where event_id = v_event and attendee_id = v_att.id;
  if not found then raise exception 'not_invited'; end if;

  if p_status = 'declined' then
    delete from public.signups where event_id = v_event and attendee_id = v_att.id;
  end if;
end
$$;

-- Permissions: helpers are private; attendee functions are open to anyone holding a valid token
revoke execute on function public._current_event_id() from public, anon, authenticated;
revoke execute on function public._write_ballot(uuid, uuid, jsonb, boolean) from public, anon, authenticated;
grant  execute on function public._current_event_id() to service_role;
grant  execute on function public._write_ballot(uuid, uuid, jsonb, boolean) to service_role;

revoke execute on function public.get_poll(text) from public;
revoke execute on function public.submit_ballot(text, jsonb) from public;
revoke execute on function public.get_event_board(text) from public;
revoke execute on function public.add_signup(text, text, text) from public;
revoke execute on function public.remove_signup(text, uuid) from public;
revoke execute on function public.set_invitation_status(text, text) from public;
grant  execute on function public.get_poll(text) to anon, authenticated;
grant  execute on function public.submit_ballot(text, jsonb) to anon, authenticated;
grant  execute on function public.get_event_board(text) to anon, authenticated;
grant  execute on function public.add_signup(text, text, text) to anon, authenticated;
grant  execute on function public.remove_signup(text, uuid) to anon, authenticated;
grant  execute on function public.set_invitation_status(text, text) to anon, authenticated;
