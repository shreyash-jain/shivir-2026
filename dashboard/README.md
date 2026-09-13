# Organiser dashboard

One static file. Live counts per session, turnout, absentee lists, CSV export.

No dependencies and no build step, same as the scanner — Supabase Auth and
PostgREST are both plain HTTP, so signing in and reading tables is `fetch` and
nothing else.

## Access

**The dashboard does not use a read policy on the volunteers' key.** If it
did, any of the fifty phones could dump the participant roll — names,
registration ids, the lot. Instead:

- the phones run as `anon` and have **no select policy at all** on
  `participants`, `scans` or `badge_links`;
- an organiser signs in through Supabase Auth and runs as `authenticated`;
- the select policies additionally require `is_organiser()`, which checks the
  signed-in user against the `organisers` table.

So being signed in is not enough. An accidental public signup gains nothing.

To add an organiser, create the user under **Authentication → Users** in the
Supabase console, then:

```sql
insert into organisers (user_id, email)
select id, email from auth.users where email = 'you@example.org';
```

To remove one, delete their row from `organisers` — no need to touch the
auth user.

## Running it

Open `index.html` over HTTPS, or locally:

```bash
python -m http.server 8000 --directory dashboard
```

Sign in with the project URL, the **publishable** key (the same public one the
phones carry — it is not a secret and it grants nothing on its own), and your
organiser email and password. The URL, key and email are remembered in
`localStorage` for next time. The signed-in session is kept in
`sessionStorage`, so a refresh does not sign you out but closing the tab does;
*Sign out* clears it. The password is never stored.

## What it shows

- **Tiles** — participants linked, scans on the selected day, badges issued,
  badges voided by reissue.
- **Sessions** — present against the number of linked participants, with the
  currently running session highlighted. Counts refresh every 20 seconds.
- **Absentees** — per session, via the `absentees()` function. Only live
  badges belonging to a real participant can be absent; an unissued spare is
  not a person.
- **Export** — scans for the selected day, all badge links, or the full roll.
  Paged at 1000 rows a request, so a 10,000-scan day exports completely rather
  than silently stopping at PostgREST's default limit.

The day picker is built from `session_days`, so it shows the ten days of the
programme rather than every date that happens to have a scan. If it is empty,
`seed_sessions.sql` has not been run.

## Notes

- The access token lasts an hour and is refreshed automatically two minutes
  before it expires. An organiser can leave this open all day.
- Polling is 20 seconds and uses `count=exact` with a zero-row range, so the
  live counts cost a count query rather than transferring rows.
- Signing out drops the token from memory. It is never written to storage.
- Everything here is read-only. There is no way to edit or delete attendance
  from this page, by design — corrections go through SQL, where they leave a
  trace.
