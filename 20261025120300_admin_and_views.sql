-- Game Night Minder: results views, scheduling logic, and admin functions

-- Yes/no tallies per date (missing votes count as neither)
create view public.poll_results with (security_invoker = true) as
select o.event_id, o.id as option_id, o.option_date,
       count(*) filter (where v.available)     as yes_count,
       count(*) filter (where not v.available) as no_count
  from public.date_options o
  left join public.votes v on v.option_id = o.id
 group by o.event_id, o.id, o.option_date;

-- Response progress: majority = MORE THAN HALF of active attendees submitted a ballot
create view public.poll_progress with (security_invoker = true) as
select e.id as event_id, t.total as total_attendees, r.responded,
       (r.responded * 2 > t.total) as majority_reached
  from public.events e
 cross join lateral (select count(*) as total from public.attendees where active) t
 cross join lateral (
   select count(*) as responded
     from public.ballots b join public.attendees a on a.id = b.attendee_id
    where b.event_id = e.id and a.active) r;

-- Winning date: most yes votes, ties go to the earliest date
create view public.poll_winner with (security_invoker = true) as
select distinct on (event_id) event_id, option_id, option_date, yes_count
  from public.poll_results
 order by event_id, yes_count desc, option_date asc;

revoke all on public.poll_results, public.poll_progress, public.poll_winner from anon;
grant select on public.poll_results, public.poll_progress, public.poll_winner to authenticated;

-- Lock in a date and decide who is invited. Used by the scheduled job.
-- Invited = voted yes on the chosen date, or never submitted a ballot.
-- Anyone who voted no on it is left out. Safe to re-run to change the date:
-- invitations are rebuilt and invites_sent_at is cleared so the job re-sends.
create or replace function public.schedule_event(p_event_id uuid, p_option_id uuid default null)
returns integer
language plpgsql security definer
set search_path = public
as $$
declare
  v_event   public.events%rowtype;
  v_option  uuid := p_option_id;
  v_date    date;
  v_settings public.app_settings%rowtype;
  v_count   integer;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if not found then raise exception 'event_not_found'; end if;
  if v_event.status = 'cancelled' then raise exception 'event_cancelled'; end if;

  if v_option is null then
    select option_id into v_option from public.poll_winner where event_id = p_event_id;
    if v_option is null then raise exception 'no_options'; end if;
  end if;

  select option_date into v_date from public.date_options
   where id = v_option and event_id = p_event_id;
  if v_date is null then raise exception 'invalid_option'; end if;

  select * into v_settings from public.app_settings where id = 1;

  update public.events
     set status = 'scheduled',
         chosen_date = v_date,
         start_time = coalesce(start_time, v_settings.default_start_time),
         location   = coalesce(location,   nullif(v_settings.default_location, '')),
         notes      = coalesce(notes,      nullif(v_settings.default_notes, '')),
         invites_sent_at = null
   where id = p_event_id;

  delete from public.invitations where event_id = p_event_id;
  insert into public.invitations (event_id, attendee_id)
  select p_event_id, a.id
    from public.attendees a
   where a.active
     and (
       not exists (select 1 from public.ballots b
                    where b.event_id = p_event_id and b.attendee_id = a.id)
       or exists (select 1 from public.ballots b
                    join public.votes v on v.ballot_id = b.id
                   where b.event_id = p_event_id and b.attendee_id = a.id
                     and v.option_id = v_option and v.available)
     );
  get diagnostics v_count = row_count;

  -- If re-scheduling dropped someone, free up their roles
  delete from public.signups s
   where s.event_id = p_event_id
     and not exists (select 1 from public.invitations i
                      where i.event_id = p_event_id and i.attendee_id = s.attendee_id);
  return v_count;
end
$$;

-- Admin-page wrappers (checked against the admins table)
create or replace function public.admin_schedule_event(p_event_id uuid, p_option_id uuid default null)
returns integer
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return public.schedule_event(p_event_id, p_option_id);
end
$$;

-- Organizer enters or edits a vote on someone's behalf (still must be complete).
-- Works even after the poll closes.
create or replace function public.admin_submit_ballot(
  p_attendee_id uuid, p_event_id uuid, p_answers jsonb
)
returns void
language plpgsql security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  perform public._write_ballot(p_attendee_id, p_event_id, p_answers, true);
end
$$;

revoke execute on function public.schedule_event(uuid, uuid) from public, anon, authenticated;
grant  execute on function public.schedule_event(uuid, uuid) to service_role;
revoke execute on function public.admin_schedule_event(uuid, uuid) from public, anon;
revoke execute on function public.admin_submit_ballot(uuid, uuid, jsonb) from public, anon;
grant  execute on function public.admin_schedule_event(uuid, uuid) to authenticated;
grant  execute on function public.admin_submit_ballot(uuid, uuid, jsonb) to authenticated;
