# Workshop attendance system

Read this before changing anything. Several decisions here look arbitrary and
are not. Where something is marked INVARIANT, changing it breaks the event.

## What this is

Attendance tracking for a 10-day residential workshop. ~1000 participants,
25-50 volunteers. Participants wear lanyard badges with a QR sticker. They
carry no phones. Volunteers scan badges at venue entrances; a scan counts
toward whichever session is running at that venue.

## Physical constraints that drive the software

- **Connectivity is patchy or absent at the venues.** Mobile data only, and a
  thousand people in one hall will congest it. Anything that requires a
  network round trip to confirm a scan will fail on day one.
- **Throughput decides whether this works.** A scan takes 2.5-4 seconds.
  That is ~20 people per minute per lane. Everyone arrives in a ten-minute
  burst before a session, not spread across the window. Clearing 1000 people
  needs 6-8 parallel scanning lanes. The UI must support 2.5s/scan:
  continuous scanning, audible and haptic confirmation, auto-advance, no
  tap-to-confirm.
- Volunteers hold the phone and scan the participant's badge. Phones are
  never handed to participants.
- Cheap Android phones, bright sun, one-handed use.

## Badge codes — INVARIANT

8 characters: 7 random + 1 check character.

Alphabet is `23456789ABCDEFGHJKMNPQRSTVWXYZ` — 30 symbols, excluding 0/O,
1/I/L and U because volunteers read these aloud and type them by hand.
Uppercase alphanumeric so the QR encodes in alphanumeric mode.

Check character: `ALPHABET[ sum( index(ch) * (i+2) ) % 30 ]` over the first 7
characters.

- The Python generator and the JavaScript app must produce identical results.
  There is a test that cross-validates them. Do not change the weights in one
  place only.
- The weights `2..8` were chosen deliberately. Weights coprime to 30 give
  100% single-substitution detection but drop transposition detection to
  ~94%; every value coprime to 30 is odd, so adjacent differences are always
  even and the trade-off cannot be avoided. Current scheme is 94%/99%.
  This was measured, not guessed. Do not "fix" it.
- Codes are random, never sequential. Sequential codes can be guessed, and a
  guessed code is a free meal.
- The checksum is only a fast offline pre-filter for a good error message.
  **The participant-list lookup is the real gate.** Both must be enforced.

Display form is `A287-3PBF`; stored form has no hyphen. Input must tolerate
hyphens, lowercase and surrounding spaces.

## QR encoding — INVARIANT

Error correction level H, printed at 35mm. Verified to decode at 100px across
under blur, sensor noise and dim light, which is roughly 65cm of working
distance on a 1080p phone. Reducing the size or the EC level costs range in a
queue where range is throughput.

The QR encodes the bare code only. Never a name, phone number or URL:
personal data on a badge is a privacy problem, and a short payload keeps the
QR sparse and fast to read.

## Offline behaviour — INVARIANT

- Every scan is written to IndexedDB immediately and confirmed from local
  state. Never await the network before showing a verdict.
- Never use localStorage or sessionStorage for scan data.
- Each scan carries a client-generated UUID and a dedupe key
  (`code|session_id|day`) so retries are idempotent.
- **Except once-per-event sessions** (`sessions.once`, e.g. certificate
  distribution running over several days). Those de-duplicate on the person:
  `once|pid|session_id`, no day, no badge — so a handout on Tuesday blocks
  Thursday, and a reissued badge cannot collect again. `ingest_scans()` sets
  this key itself from the session flag rather than trusting the phone, so an
  old APK cannot let a second one through. A second handout recorded offline
  at another desk is kept in `once_conflicts` for the admin, not dropped:
  the physical item already went out. Once sessions are excluded from
  absentees and attendance counts; only an organiser can undo one.
- The participant list lives on the phone. The app fetches `codes.csv` once
  on setup over wifi and then never needs the network again.
- A retry must be a silent no-op. A phone cannot tell "the server never got
  it" from "the response never came back". Uploads therefore go through
  `ingest_scans()` / `ingest_links()`, `security definer` functions that do
  `ON CONFLICT DO NOTHING` as the table owner and return a verdict per row.
  **Do not switch this back to a plain insert with
  `Prefer: resolution=ignore-duplicates`.** That header becomes
  `ON CONFLICT`, which under RLS needs a SELECT policy on `scans` — and the
  phones must never have one, because readable scans are a list of every
  valid badge code. Verified against the live project: the direct insert
  returned 42501 with the header and only worked without it.
- Per-row verdicts also mean one refused row (a code not on the roll) does not
  block the other 199 in its batch. The phone marks that row `rejected`, keeps
  it for the CSV export, and never re-sends it.
- Network calls need an explicit timeout. A fetch on a network that accepts
  the connection then goes silent hangs forever and, behind a `syncing`
  guard, freezes the queue for the rest of the day.

## Known bug, do not reintroduce

The IndexedDB helper originally resolved with the `IDBRequest` object when a
lookup found nothing, instead of `undefined`. Because an IDBRequest is
truthy, `if (!person)` never fired and **unknown badges were recorded as
present**. Any wrapper around IndexedDB must resolve to `undefined` on a
miss. There is a regression test for this; keep it.

## Session matching

Sessions are `(id, name, venue, start, end)`, shared across all days, with
`session_days` saying which days each one runs. A scan is attributed to the
session **the volunteer was assigned to** by the admin, for that day. At the
start of a shift the volunteer logs in with the username and password the
admin set, and sees their sessions. The first login on a given phone needs
signal; the phone then keeps a per-device salted hash so the same person can
log in again on it offline. Nothing about a volunteer who has never used a
phone is stored on it.

Do not attribute scans by venue and clock time. Sessions run late, windows
overlap, and two sessions can run at once — venue+clock cannot separate them
and silently files hundreds of scans under the wrong event. `activeAt(venue)`
was removed for this reason; do not reintroduce it. A volunteer can still
scan a session they were not assigned to, behind a confirm, and the scan is
recorded with `assigned = false` so the count can be explained.

## Security model

Volunteer phones hold the Supabase publishable key, which is designed to be
public but only safe with RLS on. Phones can call `ingest_scans()` and
`ingest_links()`, and read the schedule, the duty roster and volunteer names
(what a phone needs to work offline). They cannot read the participant roll
or the scans, and cannot update or delete anything. `scans.code` has a
foreign key to `participants(code)` so the database rejects codes that were
never issued, matching the check on the phone.

The publishable key is served to the apps from `/config.json` by a one-route
Cloudflare Worker reading encrypted secrets; rotating it is an edit in the
Cloudflare dashboard. The `service_role` key must never go there — that route
is public by design.

Organisers sign in through Supabase Auth and must also be listed in
`organisers`. They configure the event (sessions, calendar, volunteers,
assignments), load the roll, and read everything.

## Style

Plain JavaScript, no framework, no build step for the scanner. It must be
deployable as static files and runnable from cache with no network. Avoid
adding dependencies to the scanner; anything it needs must be vendored,
because the phone may never see the internet again after setup.
