# Workshop attendance

Offline-first attendance tracking for a 10-day residential workshop.
~1000 participants with QR badges, 25–50 volunteers scanning at venue
entrances. Read `CLAUDE.md` before changing anything; `SPEC.md` records the
decisions and what is left.

## Layout

| Path | What it is |
|---|---|
| `tools/` | Code and sticker-sheet generator (Python) |
| `scanner/` | The volunteer app — static files, no build step |
| `app/` | Android shell around `scanner/`, produces an installable APK |
| `backend/` | Supabase schema, the session schedule, the sync patch |
| `dashboard/` | Organiser view — live counts, absentees, CSV export |
| `tests/` | Generator tests, Python↔JS cross-validation, browser tests |

## 1. Generate badges

```bash
pip install -r tools/requirements.txt
python tools/make_qr_labels.py --count 1150 --out-dir out
```

Produces `out/codes_master.csv` (the authoritative list) and
`out/qr_labels.pdf` (58 A4 sheets, 20 stickers each at 35mm).

Print single-sided at **100% scale** — turn off "fit to page", which
silently shrinks the QR. Two guillotine cuts per sheet; the cut lines run
edge to edge.

`--per-person 2` prints each code twice so you can sticker both sides of a
badge. Lanyards flip constantly and across 1000 people that is real time.

> **Before printing 58 sheets:** print one, cut it, paste onto a real badge
> in its holder, and scan it with the cheapest phone your volunteers will
> carry, in venue lighting. Plastic holder glare is the most common failure.

Print ~15% spares for damage and reissues.

`codes_master.csv` is what makes a badge valid. Anyone holding it can forge
one, so it is gitignored and must stay out of version control.

## 2. Set up the backend

In the Supabase SQL editor, run in this order:

1. `backend/schema.sql` — tables, row-level security, reporting views.
2. `backend/seed_sessions.sql` — the 10-day programme. **Edit the start date
   and the session times at the top first.**

Until `schema.sql` runs, the project is open to anyone holding the
publishable key.

Then add yourself as an organiser so the dashboard can read anything:

```sql
-- after creating the user under Authentication -> Users
insert into organisers (user_id, email)
select id, email from auth.users where email = 'you@example.org';
```

### What each key can do

| Who | Key | Can |
|---|---|---|
| Volunteer phones | publishable | insert `scans`, insert `badge_links`, read `sessions`. Nothing else — not even reading the roll. |
| Organisers | publishable **+ a signed-in account listed in `organisers`** | read everything |

A leaked volunteer key cannot dump names, edit attendance or delete a
record. That is the whole reason the phones never get a select policy.

## 3. Deploy the scanner

**As a website.** Copy `scanner/` to any static host. HTTPS is required;
browsers only grant camera access on a secure origin. This repo deploys to
Cloudflare Pages automatically on push to `main` — see `DEPLOY.md`.

**As an Android app.** `cd app && npm run apk`. Same files, installed rather
than bookmarked, with the camera permission and keep-screen-on that a browser
cannot guarantee. See `app/README.md`. Sideloading one APK beats talking fifty
volunteers through "Add to Home Screen".

Either way, put `codes_master.csv` next to `index.html` renamed to
`codes.csv`. The app fetches it once on setup and stores it on the phone, then
never needs the network again. Do this **before** building the APK and the
roll ships inside it.

## 4. Set up the phones — on wifi, at base camp, never at the venue

1. Configure one phone fully: sessions, Supabase project URL, publishable key.
2. Tap **Copy setup for other phones**. On the website that gives a link; in
   the app it gives a short code, because the app has no address bar.
3. Send it to every volunteer. They open the link, or tap **Paste setup from
   another phone**.
4. Each volunteer enters their own name and taps **Start scanning**.

Rotating the key later is an edit on one phone and a new setup code, not a
redeploy of fifty handsets.

## 5. Registration — before anyone can be scanned in

**A badge that is not linked to a participant is refused at every venue.**
This is deliberate: attendance is meant to tie to a real person, so a badge
has to be issued at the desk before it counts. The consequence is that
pairing is on the critical path on arrival day — staff the desk accordingly.
`SPEC.md` records the decision and where to change it if you ever want a
headcount that ignores pairing.

At the desk, the volunteer picks **Register a badge**, scans the blank badge,
scans or types the participant's registration ID, types their name if it is
not already known, and taps **Link badge**. It confirms explicitly rather than
auto-advancing — this is the slow flow, not the queue flow.

Reissues are handled: linking a participant to a new badge voids their old
one, and the old badge is then refused at venues with "Badge was replaced".
A badge already linked to somebody else is refused, naming the holder.

Pairing works offline and queues exactly like scans do.

## 6. During the event

Volunteers pick their station at the start of a shift. A scan counts toward
whichever session is running at that venue, with 20 minutes of grace either
side.

Plan for **6–8 parallel scanning lanes** at major sessions. One lane clears
about 20 people per minute, and everyone arrives in a ten-minute burst
before a session rather than spread across the window.

If a badge won't scan, the volunteer types the code printed under the QR.
It validates offline.

The **≡** review sheet shows what is queued, what has been sent, and — when
something is wrong — what. "Server rejected N records" means the scans are
still safe on the phone; export the CSV rather than losing them.

## 7. Watching it happen

Open `dashboard/` and sign in as an organiser. Live counts per session,
turnout against the number of linked participants, absentee lists per
session, and CSV export per day. See `dashboard/README.md`.

## Tests

```bash
pip install -r tests/requirements.txt
python -m playwright install chromium

python -m pytest tests/ -v          # everything (~3 min)
node tests/crossvalidate.js         # Python ↔ JS checksum agreement
```

| File | Covers |
|---|---|
| `test_codes.py` | uniqueness, checksums, measured typo-detection rates, full generator run |
| `crossvalidate.js` | the real functions from `index.html` against Python over 3000 codes |
| `test_scanner.py` | fake camera: linked recorded, unlinked refused, forged refused, lingering counted once |
| `test_pairing.py` | linking, reissue voids exactly one badge, badge-in-use refused, pairings survive a roll reload |
| `test_sync.py` | one scan → one row, offline drain without duplicates, hung server does not wedge the queue, rejections surfaced |

The browser tests render real QR codes with the same reportlab path used for
the printed sheets and feed them to Chromium as a webcam, so a decode failure
in the tests is a decode failure at the venue.
