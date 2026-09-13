# Deployment

Three things ship, from one repository:

| What | Where | How |
|---|---|---|
| Scanner (volunteers) | https://shivir-attendance.shreyash-d60.workers.dev | Cloudflare, on push to `main` |
| Dashboard (organisers) | …/dashboard/ | same deploy |
| Android app | sideloaded APK | built locally, `cd app && npm run apk` |

Source: https://github.com/shreyash-jain/shivir-2026

## What gets published

`tools/build_site.sh` assembles `dist/`:

```
dist/index.html        scanner/index.html, byte-identical
dist/jsQR.min.js       vendored decoder
dist/sw.js             service worker
dist/manifest.json
dist/icon.svg
dist/dashboard/        the organiser page
dist/_headers          cache and security headers
```

Nothing is compiled, bundled or minified — every file is a verbatim copy.
`CLAUDE.md`, `SPEC.md`, `tests/`, `tools/` and `backend/` are not published.

**`codes.csv` is never deployed.** It is the participant list, and anyone
holding it can forge a badge, so it is gitignored and absent from CI. The live
site returns 404 for it and the app falls back to asking a volunteer to pick
the file during setup. If you want the roll to ship with the app, put it at
`scanner/codes.csv` and build the APK — that copy stays on the phones you
hand out rather than on a public URL.

## Caching

`index.html`, `sw.js` and the dashboard are served `no-cache`. A phone that
caches a stale `index.html` keeps an old service worker and an old sync path
for the rest of the event, and the service worker is what provides offline —
so the *network* copy must always be revalidated. `codes.csv`, if ever
present, is `no-store`.

## Deploying by hand

```bash
sh tools/build_site.sh
npx wrangler deploy
```

`wrangler.jsonc` holds the project name and points `assets.directory` at
`dist`. There is no Worker script: this serves static assets and nothing else,
which is the point.

## Deploying from CI

`.github/workflows/deploy.yml` runs the tests on every push and PR, and
deploys on `main`. The deploy step needs two repository secrets, under
**Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | a token with **Workers Scripts: Edit** |
| `CLOUDFLARE_ACCOUNT_ID` | `d60288bf2c2eef6024b2ca01c98c7408` |

Until both exist the deploy step fails and the site simply stays on its last
good version. The tests still run.

The tests run *before* the deploy on purpose. The one that matters is
`crossvalidate.js`: if the Python generator and the JavaScript app ever
disagree on the check character, every badge at the event fails to scan, and
no amount of redeploying fixes badges that are already printed and stuck to
a thousand lanyards.

## A note on the hosting move

`wrangler pages project create` now provisions a Worker with static assets
rather than a classic Pages project — Cloudflare has folded Pages into
Workers. That is why the config is `wrangler.jsonc` with an `assets` block and
the deploy command is `wrangler deploy` rather than `wrangler pages deploy`.
Behaviour for a static site is the same, including `_headers`.

## Before the event

- [ ] Run `backend/schema.sql` then `backend/seed_sessions.sql` against the
      real Supabase project, after editing the start date and session times.
- [ ] Add organisers to the `organisers` table.
- [ ] Confirm a publishable key can insert a scan and **cannot** select from
      `participants`.
- [ ] Put `codes_master.csv` at `scanner/codes.csv`, build the APK, install it
      on one cheap handset, and scan a real printed badge in venue lighting.
- [ ] Configure that phone fully, then use **Copy setup for other phones** to
      set up the rest.

`SPEC.md` has the full list of what is still unverified.
