# Game Night Minder

Monthly game day organizer: automatic date poll, invitations, volunteer sign-ups, and an organizer summary.

**Stack:** static site on GitHub Pages, Supabase (Postgres + Auth) for data, a daily GitHub Actions job for scheduling and Gmail sending.

## Status

- [x] Database schema, security rules, and scheduling logic (`supabase/migrations/`)
- [ ] Vote and volunteer pages
- [ ] Admin page
- [ ] Scheduled job and email templates

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
- **Invitations** go to everyone who voted yes on the chosen date plus anyone who never submitted a ballot. Anyone who voted no is left out.
- **Attendees** have no accounts. Each has a private link containing a token, and all public access goes through token-checked database functions.
- **The organizer** logs in on the admin page. Only users listed in the `admins` table have access.
