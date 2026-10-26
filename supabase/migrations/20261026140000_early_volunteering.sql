-- Game Night Minder: let people offer to host / bring things while the poll is still open.
-- Offers from anyone who ends up not invited (voted no on the chosen date) are removed
-- automatically when the date is locked in (see schedule_event).

create or replace function public._signups_json(p_event_id uuid, p_attendee_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'role', s.role, 'details', s.details,
           'name', a.name, 'mine', s.attendee_id = p_attendee_id) order by s.created_at), '[]'::jsonb)
    from public.signups s join public.attendees a on a.id = s.attendee_id
   where s.event_id = p_event_id
$$;
revoke execute on function public._signups_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function public._signups_json(uuid, uuid) to service_role;

create or replace function public.get_signups(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_att public.attendees%rowtype; v_event uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  v_event := public._current_event_id();
  if v_event is null then return '[]'::jsonb; end if;
  return public._signups_json(v_event, v_att.id);
end $$;
revoke execute on function public.get_signups(text) from public;
grant  execute on function public.get_signups(text) to anon, authenticated;

-- Vote page payload now includes volunteer offers
create or replace function public.get_poll(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
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
    'event', jsonb_build_object('month', v_event.month, 'status', v_event.status,
                                'poll_closes_at', v_event.poll_closes_at, 'chosen_date', v_event.chosen_date),
    'has_submitted', exists (select 1 from public.ballots where event_id = v_event.id and attendee_id = v_att.id),
    'options', coalesce((
      select jsonb_agg(jsonb_build_object('id', o.id, 'date', o.option_date, 'available', v.available) order by o.option_date)
        from public.date_options o
        left join public.ballots b on b.event_id = o.event_id and b.attendee_id = v_att.id
        left join public.votes v on v.ballot_id = b.id and v.option_id = o.id
       where o.event_id = v_event.id), '[]'::jsonb),
    'people',  public._people_json(v_event.id),
    'signups', public._signups_json(v_event.id, v_att.id),
    'posts',   public._posts_json(v_event.id, v_att.id));
end $$;

-- Sign-up works during the poll (any active attendee) and after the date is locked
-- (guests who are yes or pending; volunteering then counts as a yes).
create or replace function public.add_signup(p_token text, p_role text, p_details text default '', p_address text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_att    public.attendees%rowtype;
  v_event  uuid;
  v_status text;
  v_id     uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if p_role not in ('host', 'food', 'beverage', 'game') then raise exception 'invalid_role'; end if;
  if p_role = 'host' and length(trim(coalesce(p_address, ''))) = 0 then raise exception 'address_required'; end if;

  select id, status into v_event, v_status from public.events where id = public._current_event_id();
  if v_event is null or v_status not in ('polling', 'scheduled') then raise exception 'not_scheduled'; end if;
  if v_status = 'scheduled' and not exists (
       select 1 from public.invitations
        where event_id = v_event and attendee_id = v_att.id and status in ('yes', 'pending')) then
    raise exception 'not_invited';
  end if;

  begin
    insert into public.signups (event_id, attendee_id, role, details, address)
    values (v_event, v_att.id, p_role, left(coalesce(p_details, ''), 200),
            case when p_role = 'host' then left(trim(p_address), 200) end)
    returning id into v_id;
  exception when unique_violation then raise exception 'host_taken';
  end;

  update public.invitations set status = 'yes', responded_at = now()
   where event_id = v_event and attendee_id = v_att.id and status = 'pending';
  return v_id;
end $$;
