-- Game Night Minder: the sign-up field is always required.
-- Host: an address is required (stored privately on the sign-up).
-- Food / beverage / game: a description of what the person is bringing is required.
-- One host per event is enforced by the unique index signups_one_host_per_event
-- (created in the core tables migration); other roles allow any number of sign-ups.

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
  if p_role <> 'host' and length(trim(coalesce(p_details, ''))) = 0 then raise exception 'details_required'; end if;

  select id, status into v_event, v_status from public.events where id = public._current_event_id();
  if v_event is null or v_status not in ('polling', 'scheduled') then raise exception 'not_scheduled'; end if;
  if v_status = 'scheduled' and not exists (
       select 1 from public.invitations
        where event_id = v_event and attendee_id = v_att.id and status in ('yes', 'pending')) then
    raise exception 'not_invited';
  end if;

  begin
    insert into public.signups (event_id, attendee_id, role, details, address)
    values (v_event, v_att.id, p_role,
            case when p_role = 'host' then '' else left(trim(p_details), 200) end,
            case when p_role = 'host' then left(trim(p_address), 200) end)
    returning id into v_id;
  exception when unique_violation then raise exception 'host_taken';
  end;

  update public.invitations set status = 'yes', responded_at = now()
   where event_id = v_event and attendee_id = v_att.id and status = 'pending';
  return v_id;
end $$;
