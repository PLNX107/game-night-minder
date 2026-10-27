-- Game Night Minder: lets the scheduled job send the organizer a summary only when something changed
alter table public.events
  add column organizer_digest     text,
  add column organizer_summary_at timestamptz;
