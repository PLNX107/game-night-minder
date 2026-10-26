-- Game Night Minder: RSVP states and address gating
-- Invitation status becomes: yes (confirmed), pending (invited, no reply yet), declined.
-- The host address is shown only to "yes" guests, and only after invitations are marked sent.
-- Safe to apply whether or not the previous migration was applied by hand.

alter table public.invitations drop constraint invitations_status_check;
update public.invitations i
   set status = case when exists (select 1 from public.ballots b
                                   where b.event_id = i.event_id and b.attendee_id = i.attendee_id)
                     then 'yes' else 'pending' end
 where status = 'invited';
alter table public.invitations alter column status set default 'pending';
alter table public.invitations add constraint invitations_status_check
  check (status in ('yes', 'pending', 'declined'));

-- Tracking for the email job: when each guest got the summary-with-address, and the reminder
alter table public.invitations
  add column responded_at    timestamptz,
  add column details_sent_at timestamptz,
  add column reminder_sent_at timestamptz;
alter table public.app_settings
  add column invite_reminder_days int not null default 3 check (invite_reminder_days between 1 and 30);

-- Lock in a date. Voted yes on that date = yes; never voted = pending; voted no = not invited.
create or replace function public.schedule_event(p_event_id uuid, p_option_id uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_event    public.events%rowtype;
  v_option   uuid := p_option_id;
  v_date     date;
  v_settings public.app_settings%rowtype;
  v_count    integer;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'event_not_found'; end if;
  if v_event.status = 'cancelled' then raise exception 'event_cancelled'; end if;
  if v_option is null then
    select option_id into v_option from public.poll_winner where event_id = p_event_id;
    if v_option is null then raise exception 'no_options'; end if;
  end if;
  select option_date into v_date from public.date_options where id = v_option and event_id = p_event_id;
  if v_date is null then raise exception 'invalid_option'; end if;
  select * into v_settings from public.app_settings where id = 1;

  update public.events
     set status = 'scheduled', chosen_date = v_date,
         start_time = coalesce(start_time, v_settings.default_start_time),
         location   = coalesce(location,   nullif(v_settings.default_location, '')),
         notes      = coalesce(notes,      nullif(v_settings.default_notes, '')),
         invites_sent_at = null
   where id = p_event_id;

  delete from public.invitations where event_id = p_event_id;
  insert into public.invitations (event_id, attendee_id, status, responded_at)
  select p_event_id, a.id,
         case when has.b then 'yes' else 'pending' end,
         case when has.b then now() end
    from public.attendees a
   cross join lateral (select exists (select 1 from public.ballots b
                        where b.event_id = p_event_id and b.attendee_id = a.id) as b) has
   where a.active
     and (not has.b
          or exists (select 1 from public.ballots b join public.votes v on v.ballot_id = b.id
                      where b.event_id = p_event_id and b.attendee_id = a.id
                        and v.option_id = v_option and v.available));
  get diagnostics v_count = row_count;

  delete from public.signups s
   where s.event_id = p_event_id
     and not exists (select 1 from public.invitations i
                      where i.event_id = p_event_id and i.attendee_id = s.attendee_id);
  return v_count;
end $$;

-- RSVP: 'yes' or 'declined'. Declining frees up the guest's roles.
create or replace function public.set_invitation_status(p_token text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_att   public.attendees%rowtype;
  v_event uuid;
begin
  if p_status not in ('yes', 'declined') then raise exception 'invalid_status'; end if;
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  v_event := public._current_event_id();
  update public.invitations
     set status = p_status, responded_at = now(),
         declined_at = case when p_status = 'declined' then now() else null end
   where event_id = v_event and attendee_id = v_att.id;
  if not found then raise exception 'not_invited'; end if;
  if p_status = 'declined' then
    delete from public.signups where event_id = v_event and attendee_id = v_att.id;
  end if;
end $$;

-- Volunteering counts as saying yes
create or replace function public.add_signup(p_token text, p_role text, p_details text default '', p_address text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_att   public.attendees%rowtype;
  v_event uuid;
  v_id    uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  if p_role not in ('host', 'food', 'beverage', 'game') then raise exception 'invalid_role'; end if;
  if p_role = 'host' and length(trim(coalesce(p_address, ''))) = 0 then raise exception 'address_required'; end if;
  select id into v_event from public.events where id = public._current_event_id() and status = 'scheduled';
  if v_event is null then raise exception 'not_scheduled'; end if;
  if not exists (select 1 from public.invitations
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

-- Volunteer page payload: address only for confirmed guests after invitations are marked sent
create or replace function public.get_event_board(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_att   public.attendees%rowtype;
  v_event public.events%rowtype;
  v_inv   public.invitations%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  select * into v_event from public.events where id = public._current_event_id() and status = 'scheduled';
  if not found then
    return jsonb_build_object('attendee', jsonb_build_object('name', v_att.name), 'event', null);
  end if;
  select * into v_inv from public.invitations where event_id = v_event.id and attendee_id = v_att.id;
  return jsonb_build_object(
    'attendee', jsonb_build_object('name', v_att.name),
    'invitation_status', v_inv.status,
    'event', jsonb_build_object(
      'chosen_date', v_event.chosen_date, 'start_time', v_event.start_time, 'notes', v_event.notes,
      'location', case when v_inv.status = 'yes' and v_event.invites_sent_at is not null
        then coalesce((select s.address from public.signups s where s.event_id = v_event.id and s.role = 'host'), v_event.location) end),
    'signups', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id, 'role', s.role, 'details', s.details,
               'name', a.name, 'mine', s.attendee_id = v_att.id) order by s.created_at)
        from public.signups s join public.attendees a on a.id = s.attendee_id
       where s.event_id = v_event.id), '[]'::jsonb),
    'options', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'date', o.option_date) order by o.option_date)
                           from public.date_options o where o.event_id = v_event.id), '[]'::jsonb),
    'people', public._people_json(v_event.id),
    'posts',  public._posts_json(v_event.id, v_att.id));
end $$;
