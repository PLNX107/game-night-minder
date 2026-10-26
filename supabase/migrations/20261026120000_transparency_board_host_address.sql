-- Game Night Minder: shared visibility, message board, private host address

-- Host address: stored on the host's sign-up, shown only to invited guests once invitations are sent
alter table public.signups add column address text check (address is null or length(address) <= 200);
alter table public.signups add constraint host_needs_address
  check (role <> 'host' or length(trim(coalesce(address, ''))) > 0) not valid;

-- Message board (one board per event)
create table public.posts (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  attendee_id uuid references public.attendees(id) on delete set null,  -- null = organizer
  author_name text not null,
  body        text not null check (length(trim(body)) between 1 and 1000),
  created_at  timestamptz not null default now()
);
create index posts_event_idx on public.posts (event_id, created_at);
alter table public.posts enable row level security;
revoke all on public.posts from anon, authenticated;
grant select, insert, update, delete on public.posts to authenticated;
create policy admin_all on public.posts for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

-- Internal builders for the shared lists
create or replace function public._people_json(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', a.name,
           'responded', b.id is not null,
           'answers', (select jsonb_object_agg(v.option_id, v.available) from public.votes v where v.ballot_id = b.id),
           'invitation', i.status) order by a.name), '[]'::jsonb)
    from public.attendees a
    left join public.ballots b on b.event_id = p_event_id and b.attendee_id = a.id
    left join public.invitations i on i.event_id = p_event_id and i.attendee_id = a.id
   where a.active
$$;

create or replace function public._posts_json(p_event_id uuid, p_attendee_id uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'name', p.author_name, 'body', p.body, 'at', p.created_at,
           'mine', coalesce(p.attendee_id = p_attendee_id, false)) order by p.created_at), '[]'::jsonb)
    from (select * from public.posts where event_id = p_event_id order by created_at desc limit 100) p
$$;

-- Vote page payload: now includes everyone's votes and the message board
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
    'people', public._people_json(v_event.id),
    'posts',  public._posts_json(v_event.id, v_att.id));
end $$;

-- Volunteer page payload. The address is returned only to invited guests, and only
-- after invitations are marked sent. A host's address wins over the event default.
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
      'location', case when v_inv.status = 'invited' and v_event.invites_sent_at is not null
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

-- Sign-up now takes an address (required for host)
drop function public.add_signup(text, text, text);
create function public.add_signup(p_token text, p_role text, p_details text default '', p_address text default null)
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
                  where event_id = v_event and attendee_id = v_att.id and status = 'invited') then
    raise exception 'not_invited';
  end if;
  begin
    insert into public.signups (event_id, attendee_id, role, details, address)
    values (v_event, v_att.id, p_role, left(coalesce(p_details, ''), 200),
            case when p_role = 'host' then left(trim(p_address), 200) end)
    returning id into v_id;
  exception when unique_violation then raise exception 'host_taken';
  end;
  return v_id;
end $$;

-- Message board functions
create or replace function public.get_posts(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_att public.attendees%rowtype; v_event uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  v_event := public._current_event_id();
  if v_event is null then return '[]'::jsonb; end if;
  return public._posts_json(v_event, v_att.id);
end $$;

create or replace function public.add_post(p_token text, p_body text)
returns void language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype; v_event uuid;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  v_event := public._current_event_id();
  if v_event is null then raise exception 'not_scheduled'; end if;
  if (select count(*) from public.posts where attendee_id = v_att.id and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'too_many_posts';
  end if;
  insert into public.posts (event_id, attendee_id, author_name, body)
  values (v_event, v_att.id, v_att.name, left(trim(p_body), 1000));
end $$;

create or replace function public.delete_post(p_token text, p_post_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_att public.attendees%rowtype;
begin
  select * into v_att from public.attendees where token = p_token and active;
  if not found then raise exception 'invalid_link'; end if;
  delete from public.posts where id = p_post_id and attendee_id = v_att.id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- Organizer: mark invitations as sent (the job does this itself once email exists)
create or replace function public.admin_mark_invites_sent(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  update public.events set invites_sent_at = now() where id = p_event_id and status = 'scheduled';
  if not found then raise exception 'not_scheduled'; end if;
end $$;

-- Permissions
revoke execute on function public._people_json(uuid) from public, anon, authenticated;
revoke execute on function public._posts_json(uuid, uuid) from public, anon, authenticated;
grant  execute on function public._people_json(uuid), public._posts_json(uuid, uuid) to service_role;
revoke execute on function public.add_signup(text, text, text, text), public.get_posts(text),
  public.add_post(text, text), public.delete_post(text, uuid) from public;
grant  execute on function public.add_signup(text, text, text, text), public.get_posts(text),
  public.add_post(text, text), public.delete_post(text, uuid) to anon, authenticated;
revoke execute on function public.admin_mark_invites_sent(uuid) from public, anon;
grant  execute on function public.admin_mark_invites_sent(uuid) to authenticated;
