-- Game Night Minder: row-level security
-- Model: the public (anon) role gets NO direct table access. Attendees use the
-- token-based functions in the next migration. Only listed admins can read or
-- change data from the admin page. The scheduled job uses the service role,
-- which bypasses RLS.

create or replace function public.is_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated, service_role;

alter table public.app_settings enable row level security;
alter table public.attendees    enable row level security;
alter table public.events       enable row level security;
alter table public.date_options enable row level security;
alter table public.ballots      enable row level security;
alter table public.votes        enable row level security;
alter table public.invitations  enable row level security;
alter table public.signups      enable row level security;
alter table public.email_log    enable row level security;
alter table public.admins       enable row level security;  -- no policies: nobody can read it directly

-- Belt and braces: remove default table grants, then add back only what is needed
revoke all on all tables in schema public from anon;
revoke all on all tables in schema public from authenticated;

grant select, insert, update, delete on
  public.app_settings, public.attendees, public.events, public.date_options,
  public.invitations, public.signups
  to authenticated;
-- Ballots and votes: admin may read; writes go through admin_submit_ballot() only
grant select on public.ballots, public.votes, public.email_log to authenticated;

create policy admin_all on public.app_settings for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all on public.attendees for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all on public.events for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all on public.date_options for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all on public.invitations for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));
create policy admin_all on public.signups for all to authenticated
  using ((select public.is_admin())) with check ((select public.is_admin()));

create policy admin_read on public.ballots   for select to authenticated using ((select public.is_admin()));
create policy admin_read on public.votes     for select to authenticated using ((select public.is_admin()));
create policy admin_read on public.email_log for select to authenticated using ((select public.is_admin()));
