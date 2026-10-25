-- Game Night Minder: core tables
-- Security (RLS, grants) is in the next migration. Nothing here is readable by the public.

-- One-row settings table (defaults copied onto each event when it is scheduled)
create table public.app_settings (
  id                 int primary key default 1 check (id = 1),
  default_start_time time not null default '14:00',
  default_location   text not null default '',
  default_notes      text not null default '',
  poll_window_days   int  not null default 7 check (poll_window_days between 1 and 30),
  updated_at         timestamptz not null default now()
);
insert into public.app_settings (id) values (1);

-- Roster, managed by the organizer. The token is the attendee's private link key.
create table public.attendees (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(trim(name)) between 1 and 100),
  email      text not null check (email like '%_@_%._%'),
  token      text not null unique
             default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index attendees_email_lower_idx on public.attendees (lower(email));

-- One event per month. "month" is the first day of the month being planned.
create table public.events (
  id             uuid primary key default gen_random_uuid(),
  month          date not null unique check (month = date_trunc('month', month)::date),
  status         text not null default 'polling'
                 check (status in ('polling', 'scheduled', 'cancelled')),
  poll_opened_at timestamptz not null default now(),
  poll_closes_at timestamptz not null default (now() + interval '7 days'),
  chosen_date    date,
  start_time     time,
  location       text,
  notes          text,
  invites_sent_at  timestamptz,
  reminder_sent_at timestamptz,
  created_at     timestamptz not null default now(),
  check (status <> 'scheduled' or chosen_date is not null)
);

-- Candidate dates (normally every Saturday of the month)
create table public.date_options (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  option_date date not null,
  unique (event_id, option_date)
);

-- A submitted ballot = this person responded. Votes are written only through
-- database functions, which require an explicit yes/no for every date.
create table public.ballots (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events(id) on delete cascade,
  attendee_id  uuid not null references public.attendees(id) on delete cascade,
  submitted_at timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (event_id, attendee_id)
);

create table public.votes (
  ballot_id uuid not null references public.ballots(id) on delete cascade,
  option_id uuid not null references public.date_options(id) on delete cascade,
  available boolean not null,
  primary key (ballot_id, option_id)
);

-- Who received the final invitation, and whether they later declined
create table public.invitations (
  event_id    uuid not null references public.events(id) on delete cascade,
  attendee_id uuid not null references public.attendees(id) on delete cascade,
  status      text not null default 'invited' check (status in ('invited', 'declined')),
  invited_at  timestamptz not null default now(),
  declined_at timestamptz,
  primary key (event_id, attendee_id)
);

-- Volunteer roles. Many food/beverage/game entries allowed, but only one host.
create table public.signups (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  attendee_id uuid not null references public.attendees(id) on delete cascade,
  role        text not null check (role in ('host', 'food', 'beverage', 'game')),
  details     text not null default '' check (length(details) <= 200),
  created_at  timestamptz not null default now()
);
create unique index signups_one_host_per_event on public.signups (event_id) where role = 'host';

-- Every email the job sends (or would send in dry-run mode)
create table public.email_log (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid references public.events(id) on delete set null,
  attendee_id uuid references public.attendees(id) on delete set null,
  kind        text not null,
  recipient   text not null,
  status      text not null check (status in ('sent', 'failed', 'dry_run')),
  error       text,
  created_at  timestamptz not null default now()
);
create index email_log_lookup_idx on public.email_log (event_id, attendee_id, kind);

-- Who may use the admin page (filled in manually; see README)
create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
