# Spec — repository layout, decisions, remaining work

Read CLAUDE.md first.

## Repository layout

```
attendance/
├── CLAUDE.md                  project context (read every session)
├── SPEC.md                    this file
├── README.md                  how to run the event
├── DEPLOY.md                  hosting, CI, and how a push reaches the phones
├── .gitignore                 codes.csv, *.pdf, out/, node_modules/, APKs
│
├── tools/
│   ├── make_qr_labels.py      generates codes + printable sticker sheets
│   └── requirements.txt       reportlab
│
├── scanner/                   static PWA — deploy as-is, no build step
│   ├── index.html             the whole app
│   ├── jsQR.min.js            vendored, camera fallback decoder
│   ├── sw.js                  service worker, cache-first
│   ├── manifest.json
│   ├── icon.svg
│   └── codes.csv              generated, not committed
│
├── app/                       Capacitor shell → installable APK
│   ├── capacitor.config.json  webDir points at ../scanner, no second copy
│   ├── README.md              build prerequisites and gotchas
│   └── android/               generated; two files hand-edited
│
├── backend/
│   ├── schema.sql             tables, RLS, trigger, reporting views
│   ├── seed_sessions.sql      the 10-day schedule
│   └── supabase-sync.js       the original sync patch, now applied
│
├── dashboard/
│   ├── index.html             organiser view, no dependencies
│   └── README.md              access model
│
└── tests/
    ├── conftest.py            shared fixtures: rendered QRs, fake camera
    ├── browser.py             helpers for driving the app
    ├── test_codes.py          checksum, uniqueness, typo rates
    ├── crossvalidate.js       Python and JS checksums agree
    ├── test_scanner.py        Playwright, fake camera
    ├── test_pairing.py        registration desk, reissues
    └── test_sync.py           upload, offline drain, timeouts
```

## Decisions taken, and why

These were open questions. They are now settled; changing one means changing
code and tests together.

**Unpaired badges are refused at venues.** A badge with no participant id
linked to it shows "Badge not linked yet — send them to registration to link
it" and does not count. Attendance therefore ties to a real person, and a
printed-but-unissued spare is worth nothing if it is lost or copied.

The cost is that registration is on the critical path: on arrival day, nobody
can be marked present until the desk has issued their badge. Staff it
accordingly. If you ever want the opposite — a headcount that ignores
pairing — it is one line in `record()` (search for "Badge not linked yet")
and the matching test in `test_scanner.py::test_unpaired_badge_is_refused`.

**Session ids are shared across the ten days.** One `pray-am` row, not ten,
with the date on the scan (`scans.day`). `sessions.starts` is a `time` and
cannot hold a date, so this was the only option that did not mean rewriting
the schema, the sync mapping and `absentees()`.

`session_days` then records which days each session actually runs, so arrival
day and departure day differ from the eight in between without per-day ids. A
session that runs at a *different time* on different days needs its own id;
`session-1-short` in `seed_sessions.sql` is the pattern.

`absentees()` stays a two-argument lookup: `absentees('pray-am', '2026-12-22')`.

**The dashboard authenticates as a person, not with the volunteers' key.**
Phones have no select policy at all. Organisers sign in through Supabase Auth
and must additionally appear in the `organisers` table. A leaked publishable
key cannot read the roll. See `dashboard/README.md`.

**Pairing syncs as an append-only log, not as an update.** Phones cannot
update `participants` — that would mean granting write access to the roll to a
key sitting on fifty unattended handsets. A phone inserts into `badge_links`
and a `security definer` trigger applies it. The log doubles as the audit
trail.

Phones sync out of order, so every decision in that trigger is made on
`linked_at` — the time on the phone — and never on arrival order. A reissue
recorded at 09:10 that lands after the 09:40 link which superseded it is
discarded rather than applied.

## What exists and is tested

**`tools/make_qr_labels.py`** — generates N unique codes and a print-ready A4
sticker sheet, 20 labels per sheet at 35mm. Outputs `codes_master.csv` (the
authoritative list) and `qr_labels.pdf`. Verified: 1150/1150 codes unique and
checksum-valid; all 20 QRs on a rendered sheet decode and match the CSV.

**`scanner/index.html`** — setup, station picker, camera scanning, manual
entry with offline checksum validation, duplicate detection, registration
pairing, IndexedDB queue, Supabase sync, CSV export.

**`backend/schema.sql`** — participants, sessions, session_days, scans,
badge_links, the pairing trigger, RLS for both phones and organisers,
`attendance_by_session`, `attendance_vs_expected`, `absentees()`.
⚠️ **Reviewed but never executed** — there is no Postgres in this environment.
Run it against a scratch Supabase project before the event, not on the day.

**`backend/seed_sessions.sql`** — the 10-day programme. The start date and the
times are placeholders matching the scanner's built-in defaults; edit both
before running. Same caveat: not executed.

**`dashboard/index.html`** — live counts, turnout, absentees, paged CSV
export. Its JavaScript parses and the access model is the one described above,
but like the SQL it has not been run against a live project.

**`app/`** — Capacitor shell. Builds a 4.1 MB debug APK containing the same
scanner files. Verified: correct package id, `CAMERA` and `VIBRATE`
permissions, camera declared not-required so it installs anywhere, portrait
locked, and the current `index.html` inside the bundle. Not yet installed on a
handset.

## Test suite — 29 Python tests plus 5 cross-validation checks, all passing

```bash
python -m pytest tests/ -v      # ~3 min
node tests/crossvalidate.js
```

- `test_codes.py` — uniqueness, checksums, measured typo-detection rates
  (93.97% single-substitution, >98% transposition), full generator run.
- `crossvalidate.js` — extracts the real functions from `scanner/index.html`
  and checks them against Python over 3000 codes. Both report 93.97%,
  matching to the decimal.
- `test_scanner.py` — Chromium with a fake camera fed real rendered QR codes.
- `test_pairing.py` — linking lets a badge count; a reissue voids exactly one
  badge and nobody else's; a badge already linked is refused naming the
  holder; pairings survive re-importing the roll.
- `test_sync.py` — against a stub PostgREST: one scan is one row with the
  schema's column names, offline drains on reconnect without duplicates, sent
  rows are not re-sent, **a server that accepts the connection then goes
  silent does not wedge the queue**, and a 4xx is surfaced rather than retried
  forever.

Bugs found by writing these: `validate(None)` crashed in the generator; the
cross-validation harness could not see `const` bindings in a vm sandbox;
re-importing `codes.csv` wiped unsynced pairings; an empty name box erased a
name that had come from the printed roll. All fixed.

## Remaining work

### 1. Run the SQL against a real project
Everything in `backend/` and the whole dashboard is unexecuted. Create a
scratch Supabase project, run `schema.sql` then `seed_sessions.sql`, add an
organiser, and confirm:

- a phone with the publishable key can insert a scan and a badge link, and
  **cannot** select from `participants`;
- a reissue inserted into `badge_links` voids exactly the old badge;
- two link events for the same pid arriving out of order leave the newer one
  winning;
- `absentees('pray-am', <a day>)` returns who you expect;
- an organiser account sees the dashboard and a non-organiser account does
  not.

### 2. A real end-to-end rehearsal
Print one sheet, cut it, paste onto a real badge in its holder, and run the
APK on the cheapest handset the volunteers will carry, in venue lighting.
Register a badge at a desk, scan it at a venue, pull the plug on the wifi
mid-queue, and confirm the counts land.

### 3. Edit the schedule
`seed_sessions.sql` carries placeholder times and a placeholder start date.
They must match the real programme, and the scanner's session list must match
them — see the note at the bottom of that file.

## Operational notes worth encoding in README

- Print one sheet, cut it, paste onto a real badge in its holder, and scan it
  with the cheapest phone volunteers will carry, in venue lighting, before
  printing 58 sheets. Plastic holder glare is the most common failure.
- Print ~15% spare badges for damage and reissues.
- Configure phones on wifi at base camp, never at the venue.
- Two stickers per badge (front and back) avoids asking people to turn their
  badge around; across 1000 people that is real time.
