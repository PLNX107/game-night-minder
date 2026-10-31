# Game Night Minder

Monthly game day organizer: automatic date poll, invitations, volunteer sign-ups, and an organizer summary.

**Stack:** static site on GitHub Pages, Supabase (Postgres + Auth) for data, a daily GitHub Actions job for scheduling and Gmail sending.

## Status

- [x] Database schema, security rules, and scheduling logic (`supabase/migrations/`)
- [ ] Vote and volunteer pages
- [ ] Admin page
- [x] Scheduled job and email templates (`jobs/run.mjs`, `.github/workflows/game-night.yml`)

## Database setup

1. **Apply the migrations.** With the Supabase GitHub integration connected, pushing to the main branch applies everything in `supabase/migrations/`. Alternatively, paste the four files into the Supabase SQL editor, in filename order.
2. **Create your admin login.** In Supabase, go to Authentication, add a user with your email and a strong password, and turn off public sign-ups.
3. **Authorize that user as admin.** Run this once in the SQL editor, with your real email. Do not put it in a migration file, because this repo is public:

   ```sql
   insert into public.admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```

## Secrets (GitHub: Settings > Secrets and variables > Actions)

`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `GMAIL_ADDRESS`, `GMAIL_APP_PASSWORD`, `ORGANIZER_EMAIL`, `SITE_URL`

See `.env.example`. Never commit real values.

## How the rules work

- **Ballots** require an explicit yes or no for every date. Incomplete ballots are rejected by the database.
- **Majority** means more than half of active attendees have submitted a ballot.
- **Winning date** is the one with the most yes votes; ties go to the earliest date.
- **Invitations** go to everyone who voted yes on the chosen date (status yes) plus anyone who never submitted a ballot (status pending). Anyone who voted no is left out.
- **Address:** the host enters it when volunteering. Only guests with status yes can see it, and only after invitations are marked sent. Pending guests become yes by replying or by volunteering.
- **Email rules (for the scheduled job):** (1) invitation to yes and pending guests, no address; (2) reminder to pending guests after `invite_reminder_days`, with an event summary and no address; (3) summary with the address to each yes guest once a host address exists, sent once per guest, including guests who reply yes later.
- **Attendees** have no accounts. Each has a private link containing a token, and all public access goes through token-checked database functions.
- **The organizer** logs in on the admin page. Only users listed in the `admins` table have access.

## The Toy Box

A shared game list on every attendee page. Anyone can add a game (the person who adds it automatically ticks "I want to play this!"), tick "I own it", and tick "I want to play this!". Only the person who added a game can remove it; the organizer can remove any game from the admin page, and can pick or re-pick a game by hand.

People can also tick "I don't want to play this" (it can't be combined with "I want to play this!").

Pick rules: candidates are games owned by at least one confirmed guest (status yes), not already used for this event. Choice is weighted random, with weight = 1 + (confirmed guests who want it) - (confirmed guests who don't). A game whose weight is zero or less, meaning more confirmed guests don't want it than want it, is skipped. The pick becomes a Games entry for an owner, the host if the host owns it, otherwise a random owner among confirmed guests.

## The scheduled job

Runs every 3 hours from GitHub Actions and is safe to repeat. Each run does whatever is due:

1. **Last Sunday of the month, after 9 AM Eastern:** creates next month's poll (every Saturday) and emails everyone their personal link.
2. **When the voting window closes** (7 days later by default): if more than half have voted, locks in the winning date and sends invitations to yes and pending guests (no address). Otherwise it reminds non-voters, alerts you once, and keeps checking.
3. **After invitations:** pending guests get one reminder after `invite_reminder_days` (default 3), with an event summary and no address.
4. **Once a host has entered an address:** each guest who said yes gets the summary with the address, once. Guests who reply yes later get the same email on the next run.
5. **The Toy Box pick:** once a host has signed up (or 5 days before game day), picks a game owned by a confirmed guest. Weighted random: weight = 1 + the number of confirmed guests who ticked "I want to play this!". It becomes a Games entry for an owner, the host if the host owns it, and the owner gets an email. If the owner declines, the entry disappears and the job picks again.
6. **You get a summary** when something changes (replies, volunteers), at most every 12 hours.

Every email is recorded in the `email_log` table. A failed address is retried up to 3 times.

### Setup

1. In your Google account, create an **app password** (Security > 2-Step Verification > App passwords).
2. In the repo, go to Settings > Secrets and variables > Actions, and add **secrets**: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `GMAIL_ADDRESS`, `GMAIL_APP_PASSWORD`, `ORGANIZER_EMAIL`, `SITE_URL` (your Pages address, for example `https://YOURNAME.github.io/game-night-minder/`).
3. Test first: Actions tab > "Game Night job" > Run workflow with dry run set to `true`. It logs what it would do and sends nothing.
4. To go live, add a repository **variable** (not a secret) named `DRY_RUN` with the value `false`. Until it exists, scheduled runs stay in dry-run mode.

### Notes

- Dates and the "last Sunday" rule use Eastern time. Set a `TIMEZONE` environment variable in the workflow to change it.
- GitHub turns off scheduled workflows in a public repository after 60 days with no repository activity. If the repo goes quiet, make a small commit now and then, and check the Actions tab if emails stop.
- If you set a default address in the admin settings, guests who say yes receive it right away, even if a host signs up later with a different address.
