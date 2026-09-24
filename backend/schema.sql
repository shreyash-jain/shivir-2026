-- Attendance backend. Paste into the Supabase SQL editor.
--
-- Two kinds of client talk to this database and they get very different
-- powers:
--
--   Volunteer phones  hold the publishable key and run as `anon`. With the
--                     key alone they may call ingest_scans() and
--                     ingest_links(), and read the session schedule and the
--                     duty roster. Everything else a phone shows -- the
--                     participant roll, who is present and absent -- needs a
--                     session token from volunteer_login(), so a leaked key
--                     on its own exposes nothing personal, and deactivating a
--                     volunteer cuts their phone off. Nothing a phone holds
--                     can update or delete.
--
--   Organisers        sign in through Supabase Auth and run as
--                     `authenticated`. Only those listed in `organisers` can
--                     read the roll or configure the event. See
--                     dashboard/README.md.
--
-- Re-runnable: every statement is guarded, so you can paste the whole file
-- again after an edit without dropping data.

-- ---------------------------------------------------------------- tables

create table if not exists participants (
  code        text primary key,              -- the 8-char badge code
  serial      int,
  name        text,
  pid         text,                          -- your own registration id, if any
  void        boolean not null default false,-- set when a badge is reissued
  linked_at   timestamptz,                   -- when this badge was paired
  created_at  timestamptz not null default now()
);

alter table participants add column if not exists linked_at timestamptz;

-- A participant id may be held by only one LIVE badge, but a reissued badge
-- keeps its old pid alongside void = true so the history stays readable.
-- A plain unique constraint cannot express that, so drop it if an earlier
-- version of this file created one, and use a partial index instead.
alter table participants drop constraint if exists participants_pid_key;
create unique index if not exists participants_live_pid
  on participants (pid) where pid is not null and not void;

create table if not exists sessions (
  id      text primary key,
  name    text not null,
  venue   text not null,
  starts  time not null,
  ends    time not null,
  once    boolean not null default false  -- once per event: see ingest_scans()
);

alter table sessions add column if not exists once boolean not null default false;

-- Session ids are shared across the ten days and the date lives on the scan.
-- This table says which days each session actually runs, so that day 1 and
-- day 10 can differ and absentees() is never asked about a session that did
-- not happen. Seeded by seed_sessions.sql.
create table if not exists session_days (
  session_id text not null references sessions(id) on delete cascade,
  day        date not null,
  primary key (session_id, day)
);

-- Who is holding each phone. The super admin maintains this, sets each
-- volunteer a username and password, and a volunteer logs in on the phone at
-- the start of a shift. The first login on a given phone needs signal; after
-- that the phone remembers them and they can log in again offline.
create table if not exists volunteers (
  id         text primary key,             -- short, stable, e.g. 'v-anjali'
  name       text not null,
  username   text unique,                  -- what they type to log in
  pass_hash  text,                         -- bcrypt, via set_volunteer_password()
  phone      text,                         -- for the shift coordinator only
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

alter table volunteers add column if not exists username  text;
alter table volunteers add column if not exists pass_hash text;
create unique index if not exists volunteers_username on volunteers (lower(username));

-- Supabase puts extensions in their own schema, and the functions below pin
-- search_path to public, so crypt() and gen_salt() are schema-qualified.
create extension if not exists pgcrypto with schema extensions;

-- Which volunteer is working which session on which day.
--
-- This is what makes two concurrent sessions separable. Venue and clock time
-- alone cannot tell them apart -- see the warning in CLAUDE.md about scans
-- being filed under the wrong event -- but the volunteer knows which door
-- they are standing at, and the admin knows which door that is.
create table if not exists assignments (
  volunteer_id text not null references volunteers(id) on delete cascade,
  session_id   text not null references sessions(id)   on delete cascade,
  day          date not null,
  primary key (volunteer_id, session_id, day)
);

create index if not exists assignments_day on assignments (day);

create table if not exists scans (
  uuid         uuid primary key,             -- generated on the phone
  dedupe       text not null unique,         -- code|session|day
  code         text not null references participants(code),
  session_id   text not null,
  session_name text,
  venue        text,
  scanned_at   timestamptz not null,         -- when it happened, not when it arrived
  day          date not null,
  volunteer    text,                        -- the name, kept for plain exports
  volunteer_id text,                         -- who was assigned, when known
  device       text,
  source       text,                         -- 'camera' or 'manual'
  assigned     boolean,                      -- false when the volunteer
                                             -- overrode their assignment
  received_at  timestamptz not null default now()
);

-- Deliberately NO foreign key on volunteer_id. A phone configured before a
-- volunteer was renamed or removed would otherwise have every one of its
-- scans rejected permanently, wedging that phone's queue for the rest of the
-- day. A dangling volunteer id costs a join in a report; a rejected insert
-- costs attendance. (scans.code keeps its foreign key -- there the whole
-- point is to reject codes that were never issued.)

create index if not exists scans_session_day on scans (session_id, day);
create index if not exists scans_code on scans (code);

-- Badge pairing, as an append-only log rather than an update.
--
-- Phones cannot update `participants` -- that would mean granting update on
-- the roll to a key that sits on 50 unattended handsets. Instead a phone
-- inserts the pairing it performed, and a trigger below applies it. The log
-- is also the audit trail: who linked which badge to whom, and when.
create table if not exists badge_links (
  uuid        uuid primary key,              -- generated on the phone
  code        text not null references participants(code),
  pid         text not null,
  name        text,
  replaces    text,                          -- badge being voided, if a reissue
  linked_at   timestamptz not null,          -- when it happened on the phone
  volunteer   text,
  device      text,
  received_at timestamptz not null default now()
);

create index if not exists badge_links_pid on badge_links (pid);

-- ------------------------------------------------- applying a badge link
--
-- Phones sync whenever they find signal, so links arrive out of order: a
-- reissue recorded at 09:10 on one phone can land after the 09:40 link that
-- superseded it. Every decision here is therefore made on `linked_at`, the
-- time on the phone, and never on arrival order. An older event that has
-- already been overtaken is discarded rather than applied.

create or replace function apply_badge_link() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- Someone has already linked this participant to a badge more recently.
  -- This event is stale; keep it in the log but do not act on it.
  if exists (
    select 1 from participants
    where pid = new.pid and linked_at is not null and linked_at > new.linked_at
  ) then
    return new;
  end if;

  -- This badge itself has a newer link. Same reasoning.
  if exists (
    select 1 from participants
    where code = new.code and linked_at is not null and linked_at > new.linked_at
  ) then
    return new;
  end if;

  -- Any other badge still holding this pid is superseded by this one. This
  -- covers the reissue whether or not the phone knew about the old badge,
  -- so a replacement issued from a phone with a stale roll still voids it.
  update participants
     set void = true
   where pid = new.pid and code <> new.code and not void;

  -- The phone named a specific badge to void. Usually the same row the
  -- statement above caught, but honour it explicitly in case that badge was
  -- linked to a different pid.
  if new.replaces is not null and new.replaces <> new.code then
    update participants set void = true where code = new.replaces;
  end if;

  update participants
     set pid       = new.pid,
         name      = coalesce(nullif(new.name, ''), name),
         void      = false,
         linked_at = new.linked_at
   where code = new.code;

  return new;
end;
$$;

drop trigger if exists badge_links_apply on badge_links;
create trigger badge_links_apply
  after insert on badge_links
  for each row execute function apply_badge_link();

-- ---------------------------------------------------------------- security

alter table participants enable row level security;
alter table sessions     enable row level security;
alter table session_days enable row level security;
alter table scans        enable row level security;
alter table volunteers   enable row level security;
alter table assignments  enable row level security;
alter table badge_links  enable row level security;

-- Phones do NOT insert into scans or badge_links directly. They call the
-- ingest_* functions below. An earlier version had plain insert policies
-- here; they are dropped so that the functions are the only door in.
drop policy if exists "devices insert scans" on scans;
drop policy if exists "devices insert links" on badge_links;

-- Session times are harmless to read and let phones pick up schedule changes.
drop policy if exists "read sessions" on sessions;
create policy "read sessions"
  on sessions for select to anon
  using (true);

drop policy if exists "read session days" on session_days;
create policy "read session days"
  on session_days for select to anon
  using (true);

-- Phones need their assignments to know which of two concurrent sessions a
-- scan belongs to. Assignments are a duty roster -- who stands at which door
-- -- and carry nothing personal.
drop policy if exists "read assignments" on assignments;
create policy "read assignments"
  on assignments for select to anon
  using (true);

-- Volunteer names, without phone numbers or password hashes. Phones used to
-- read this to offer a pick-your-name list; they now log in instead and get
-- their identity from volunteer_login(), so it is organiser-only.
create or replace view volunteer_roster as
  select id, name, username from volunteers where active;

revoke all on volunteer_roster from anon;
grant select on volunteer_roster to authenticated;

-- participants has RLS on and deliberately no anon policy, so the key
-- cannot read names. Phones get the roll from the bundled codes.csv instead.
-- The foreign key on scans.code still rejects codes that were never issued.
-- volunteers is shut for the same reason: it holds password hashes.

-- ------------------------------------------------------------ conflicts
-- Two desks both offline, one person visiting each: both phones issue, the
-- server keeps the first and must not silently drop the second -- a physical
-- certificate went out. It lands here so the admin can follow up.
create table if not exists once_conflicts (
  id            bigserial primary key,
  session_id    text not null,
  pid           text,
  code          text not null,
  scanned_at    timestamptz not null,
  volunteer     text,
  device        text,
  first_uuid    uuid,                 -- the scan that was kept
  received_at   timestamptz not null default now()
);
alter table once_conflicts enable row level security;

-- ------------------------------------------------------------ ingestion
--
-- Why a function and not an insert policy.
--
-- A phone cannot tell "the server never got it" from "the reply never came
-- back", so every upload must be safe to repeat. The obvious way is
-- PostgREST's `Prefer: resolution=ignore-duplicates`, which becomes
-- INSERT ... ON CONFLICT DO NOTHING. Under row-level security that path
-- needs a SELECT policy on the table, and the phones must never have one:
-- readable scans are a list of every valid badge code, and a valid code is a
-- printable badge. Tested against the live project -- the direct insert
-- returned 42501 with the header and only worked without it.
--
-- So the phones get one capability: call these. They run as the table owner,
-- do the conflict handling themselves, and hand back a verdict per row. That
-- also means one bad row no longer poisons the other 199 in its batch -- the
-- phone is told exactly which uuid was refused and why, marks that one as
-- rejected, and moves on.
--
-- Statuses: 'ok' inserted; 'duplicate' already there (a retry, or the same
-- badge scanned twice into one session on two phones); 'rejected' a code
-- that was never issued, or a malformed row.

create or replace function ingest_scans(rows jsonb)
returns table (uuid uuid, status text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  r        jsonb;
  v_once   boolean;
  v_pid    text;
  v_dedupe text;
  v_code   text;
  v_first  uuid;
begin
  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  for r in select * from jsonb_array_elements(rows) loop
    uuid := null; status := null; detail := null;
    begin
      uuid   := (r->>'uuid')::uuid;
      v_code := r->>'code';
      v_dedupe := r->>'dedupe';

      select s.once into v_once from sessions s where s.id = r->>'session_id';
      if coalesce(v_once, false) then
        select p.pid into v_pid from participants p where p.code = v_code;
        -- Per person across the event. An unlinked badge falls back to the
        -- badge itself; the phone refuses those anyway.
        v_dedupe := 'once|' || coalesce(v_pid, 'badge:' || v_code) || '|' || (r->>'session_id');
      end if;

      -- A retry of something already stored: quiet no-op, as before.
      if exists (select 1 from scans sc where sc.uuid = (r->>'uuid')::uuid) then
        status := 'duplicate';
        return next; continue;
      end if;

      insert into scans
        (uuid, dedupe, code, session_id, session_name, venue, scanned_at, day,
         volunteer, volunteer_id, device, source, assigned)
      values
        (uuid, v_dedupe, v_code,
         r->>'session_id', r->>'session_name', r->>'venue',
         (r->>'scanned_at')::timestamptz, (r->>'day')::date,
         r->>'volunteer', r->>'volunteer_id', r->>'device', r->>'source',
         (r->>'assigned')::boolean)
      on conflict do nothing;

      if found then
        status := 'ok';
      else
        status := 'duplicate';
        -- Same person, different scan: for a once session that is a second
        -- physical handout, so keep a record of it.
        if coalesce(v_once, false) then
          select sc.uuid into v_first from scans sc where sc.dedupe = v_dedupe;
          insert into once_conflicts (session_id, pid, code, scanned_at, volunteer, device, first_uuid)
          values (r->>'session_id', v_pid, v_code, (r->>'scanned_at')::timestamptz,
                  r->>'volunteer', r->>'device', v_first);
          detail := 'already issued';
        end if;
      end if;
    exception
      when foreign_key_violation then
        status := 'rejected'; detail := 'code was never issued';
      when others then
        status := 'rejected'; detail := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

create or replace function ingest_links(rows jsonb)
returns table (uuid uuid, status text, detail text)
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
begin
  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  for r in select * from jsonb_array_elements(rows) loop
    uuid := null; status := null; detail := null;
    begin
      uuid := (r->>'uuid')::uuid;
      insert into badge_links
        (uuid, code, pid, name, replaces, linked_at, volunteer, device)
      values
        (uuid,
         r->>'code',
         r->>'pid',
         r->>'name',
         r->>'replaces',
         (r->>'linked_at')::timestamptz,
         r->>'volunteer',
         r->>'device')
      on conflict do nothing;
      status := case when found then 'ok' else 'duplicate' end;
    exception
      when foreign_key_violation then
        status := 'rejected'; detail := 'code was never issued';
      when others then
        status := 'rejected'; detail := sqlerrm;
    end;
    return next;
  end loop;
end;
$$;

-- Callable by phones and by nobody else who is not already trusted.
revoke all on function ingest_scans(jsonb) from public;
revoke all on function ingest_links(jsonb) from public;
grant execute on function ingest_scans(jsonb) to anon, authenticated;
grant execute on function ingest_links(jsonb) to anon, authenticated;

-- --------------------------------------------------------- volunteer login
--
-- A volunteer logs in with the username and password the admin set. The
-- login hands back a session token; every read the phone does afterwards --
-- the roll, attendance -- is gated by that token, never by the publishable
-- key alone. Tokens last 30 days and die the moment the volunteer is
-- deactivated, which is how a lost phone is dealt with.
--
-- A wrong username and a wrong password look identical from outside. There is
-- no lockout: the key is public, so a lockout would let anyone freeze a
-- volunteer out of their phone at the door.

create table if not exists volunteer_sessions (
  token        text primary key,
  volunteer_id text not null references volunteers(id) on delete cascade,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null
);
alter table volunteer_sessions enable row level security;   -- no policies: functions only

drop function if exists volunteer_login(text, text);
create or replace function volunteer_login(p_username text, p_password text)
returns table (id text, name text, token text)
language plpgsql security definer set search_path = public as $$
declare
  v volunteers%rowtype;
begin
  select * into v from volunteers vv
  where lower(vv.username) = lower(trim(p_username))
    and vv.active
    and vv.pass_hash is not null
    and vv.pass_hash = extensions.crypt(p_password, vv.pass_hash);
  if not found then return; end if;

  token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into volunteer_sessions (token, volunteer_id, expires_at)
  values (token, v.id, now() + interval '30 days');
  -- Housekeeping: nothing older than the window needs keeping.
  delete from volunteer_sessions where expires_at < now() - interval '7 days';

  id := v.id; name := v.name;
  return next;
end;
$$;

revoke all on function volunteer_login(text, text) from public;
grant execute on function volunteer_login(text, text) to anon, authenticated;

-- The volunteer a token belongs to, or null. Every read below starts here.
create or replace function volunteer_for_token(p_token text)
returns text
language sql stable security definer set search_path = public as $$
  select s.volunteer_id
  from volunteer_sessions s
  join volunteers v on v.id = s.volunteer_id
  where s.token = p_token and s.expires_at > now() and v.active;
$$;
revoke all on function volunteer_for_token(text) from public;

-- The participant roll, for a phone that has logged in. This is how the codes
-- get onto a handset without anyone handling a CSV. Includes pid, name and
-- void, so a reissue done on one phone reaches every other the next time its
-- volunteer logs in with signal.
--
-- Returns ONE jsonb document, not a set of rows. PostgREST caps a set at its
-- max-rows (1000 on Supabase) and truncates silently; a phone would then hold
-- serials 1-1000 and refuse every badge above that. Found with badge 1500.
drop function if exists download_roll(text, text);
drop function if exists download_roll(text);
create or replace function download_roll(p_token text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when volunteer_for_token(p_token) is null then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(jsonb_build_object(
                 'code', p.code, 'serial', p.serial, 'name', p.name,
                 'pid', p.pid, 'void', p.void) order by p.serial)
         from participants p),
      '[]'::jsonb)
  end;
$$;
revoke all on function download_roll(text) from public;
grant execute on function download_roll(text) to anon, authenticated;

-- Everyone's scans for one day, compact: [[code, session_id, scanned_at], ...].
-- A thousand people across seven sessions is ~7000 rows; as bare arrays that
-- is a few hundred KB, polled every half minute only while the phone has
-- signal and is showing an attendance tab.
create or replace function attendance_for_day(p_token text, p_day date)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when volunteer_for_token(p_token) is null then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(jsonb_build_array(s.code, s.session_id, s.scanned_at) order by s.scanned_at)
         from scans s where s.day = p_day),
      '[]'::jsonb)
  end;
$$;
revoke all on function attendance_for_day(text, date) from public;
grant execute on function attendance_for_day(text, date) to anon, authenticated;

-- One participant across the whole event: [[day, session_id, scanned_at], ...].
create or replace function participant_history(p_token text, p_code text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when volunteer_for_token(p_token) is null then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(jsonb_build_array(s.day, s.session_id, s.scanned_at) order by s.scanned_at)
         from scans s where s.code = upper(p_code)),
      '[]'::jsonb)
  end;
$$;
revoke all on function participant_history(text, text) from public;
grant execute on function participant_history(text, text) to anon, authenticated;

-- Unlink a badge: the pairing was to the wrong person, or a rehearsal.
-- A reissue cannot fix that -- it voids the badge for the same pid. This
-- resets the participant row and removes the badge's scans and link records,
-- so the badge is a clean spare again. Organiser-only, and logged: the
-- deleted rows are returned so the admin page can show what went.
create or replace function unlink_badge(p_code text)
returns table (scans_removed int, links_removed int)
language plpgsql security definer set search_path = public as $$
declare
  c text := upper(regexp_replace(p_code, '[^0-9A-Za-z]', '', 'g'));
begin
  if not is_organiser() then
    raise exception 'not an organiser' using errcode = '42501';
  end if;
  if not exists (select 1 from participants where code = c) then
    raise exception 'no such badge';
  end if;
  delete from scans where code = c;
  get diagnostics scans_removed = row_count;
  delete from badge_links where code = c;
  get diagnostics links_removed = row_count;
  update participants
     set pid = null, name = null, void = false, linked_at = null
   where code = c;
  return next;
end;
$$;
revoke all on function unlink_badge(text) from public;
grant execute on function unlink_badge(text) to authenticated;

-- Organisers set or reset a password from the admin page. Stored bcrypt;
-- the plain text is never written anywhere.
create or replace function set_volunteer_password(p_id text, p_password text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_organiser() then
    raise exception 'not an organiser' using errcode = '42501';
  end if;
  if length(coalesce(p_password, '')) < 4 then
    raise exception 'password must be at least 4 characters';
  end if;
  update volunteers
     set pass_hash = extensions.crypt(p_password, extensions.gen_salt('bf', 8))
   where volunteers.id = p_id;
  if not found then
    raise exception 'no such volunteer';
  end if;
end;
$$;

revoke all on function set_volunteer_password(text, text) from public;
grant execute on function set_volunteer_password(text, text) to authenticated;

-- ------------------------------------------------------------- organisers
--
-- Read access for the dashboard. Being signed in is not enough -- the user
-- must also be listed here, so an accidental public signup gains nothing.
--
-- To add an organiser: create the user in Authentication -> Users, then
--   insert into organisers (user_id, email)
--   select id, email from auth.users where email = 'you@example.org';

create table if not exists organisers (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

alter table organisers enable row level security;

-- security definer so the check itself is not subject to the policies below.
create or replace function is_organiser() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from organisers where user_id = auth.uid());
$$;

drop policy if exists "organisers see themselves" on organisers;
create policy "organisers see themselves"
  on organisers for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "organisers read participants" on participants;
create policy "organisers read participants"
  on participants for select to authenticated
  using (is_organiser());

drop policy if exists "organisers read scans" on scans;
create policy "organisers read scans"
  on scans for select to authenticated
  using (is_organiser());

drop policy if exists "organisers read links" on badge_links;
create policy "organisers read links"
  on badge_links for select to authenticated
  using (is_organiser());

drop policy if exists "organisers read sessions" on sessions;
create policy "organisers read sessions"
  on sessions for select to authenticated
  using (is_organiser());

drop policy if exists "organisers read session days" on session_days;
create policy "organisers read session days"
  on session_days for select to authenticated
  using (is_organiser());

-- ------------------------------------------------------- admin write access
--
-- The super admin page configures the event: sessions, the ten-day calendar,
-- the volunteer roster and who works what. All of it is organiser-only, and
-- none of it is reachable with the publishable key the phones carry.
--
-- `for all` covers insert, update and delete; both using and with check are
-- required, or an organiser could read a row and fail to write it.

drop policy if exists "organisers write sessions" on sessions;
create policy "organisers write sessions"
  on sessions for all to authenticated
  using (is_organiser()) with check (is_organiser());

drop policy if exists "organisers write session days" on session_days;
create policy "organisers write session days"
  on session_days for all to authenticated
  using (is_organiser()) with check (is_organiser());

drop policy if exists "organisers write volunteers" on volunteers;
create policy "organisers write volunteers"
  on volunteers for all to authenticated
  using (is_organiser()) with check (is_organiser());

drop policy if exists "organisers write assignments" on assignments;
create policy "organisers write assignments"
  on assignments for all to authenticated
  using (is_organiser()) with check (is_organiser());

-- Organisers may correct a participant row (a name, a typo in a pid). There
-- is deliberately no delete: a participant row with scans hanging off it
-- must not vanish, and a wrong pairing is fixed by a reissue, which leaves a
-- trace.
drop policy if exists "organisers load participants" on participants;
drop policy if exists "organisers amend participants" on participants;
create policy "organisers amend participants"
  on participants for update to authenticated
  using (is_organiser()) with check (is_organiser());

-- Loading the roll from codes_master.csv. A function, for the same reason as
-- ingest_scans(): the upload has to be repeatable, repeatable means
-- ON CONFLICT DO NOTHING, and ON CONFLICT under RLS is a trap. Existing rows
-- are never touched -- re-loading the file must not undo a pairing or
-- un-void a reissued badge. Only organisers may call it, checked inside.
create or replace function load_participants(rows jsonb)
returns table (inserted int, skipped int, rejected int)
language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
begin
  if not is_organiser() then
    raise exception 'not an organiser' using errcode = '42501';
  end if;
  if jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;

  inserted := 0; skipped := 0; rejected := 0;
  for r in select * from jsonb_array_elements(rows) loop
    begin
      insert into participants (code, serial, name, pid)
      values (r->>'code',
              nullif(r->>'serial', '')::int,
              nullif(r->>'name', ''),
              nullif(r->>'pid', ''))
      on conflict (code) do nothing;
      if found then inserted := inserted + 1; else skipped := skipped + 1; end if;
    exception when others then
      rejected := rejected + 1;
    end;
  end loop;
  return next;
end;
$$;

revoke all on function load_participants(jsonb) from public;
grant execute on function load_participants(jsonb) to authenticated;

-- once-per-event: conflicts are organiser-only
drop policy if exists "organisers read once conflicts" on once_conflicts;
create policy "organisers read once conflicts"
  on once_conflicts for select to authenticated using (is_organiser());
drop policy if exists "organisers clear once conflicts" on once_conflicts;
create policy "organisers clear once conflicts"
  on once_conflicts for delete to authenticated using (is_organiser());


-- ------------------------------------------------------------ phone reads
-- Everything already handed out in once sessions, all days, for the desk's
-- "already given" warning: [[session_id, pid, code, scanned_at, volunteer], ...].
-- A thousand rows at most per session; fetched at login and on each refresh.
create or replace function once_issued(p_token text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when volunteer_for_token(p_token) is null then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(jsonb_build_array(sc.session_id, p.pid, sc.code, sc.scanned_at, sc.volunteer)
                        order by sc.scanned_at)
         from scans sc
         join sessions s on s.id = sc.session_id and s.once
         left join participants p on p.code = sc.code),
      '[]'::jsonb)
  end;
$$;
revoke all on function once_issued(text) from public;
grant execute on function once_issued(text) to anon, authenticated;

-- ------------------------------------------------------------ undo (admin)
-- A certificate scanned by mistake. Organiser-only, by design: undoing a
-- handout at the desk would make the record meaningless.
create or replace function undo_scan(p_uuid uuid)
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_organiser() then
    raise exception 'not an organiser' using errcode = '42501';
  end if;
  delete from scans where uuid = p_uuid;
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function undo_scan(uuid) from public;
grant execute on function undo_scan(uuid) to authenticated;

-- ---------------------------------------------------------------- reporting
--
-- Views run with the privileges of their owner unless told otherwise.
-- security_invoker makes the caller's RLS apply, so a volunteer key cannot
-- read a view to get at what the tables deny.

create or replace view attendance_by_session
with (security_invoker = true) as
  select day, session_id, session_name, venue, count(*) as present
  from scans group by day, session_id, session_name, venue
  order by day, session_id;

-- Expected headcount alongside the actual, per scheduled session.
create or replace view attendance_vs_expected
with (security_invoker = true) as
  select d.day,
         s.id   as session_id,
         s.name as session_name,
         s.venue,
         s.starts,
         s.ends,
         (select count(*) from participants p where not p.void and p.pid is not null)
           as expected,
         (select count(*) from scans sc
           where sc.session_id = s.id and sc.day = d.day) as present
  from session_days d
  join sessions s on s.id = d.session_id
  order by d.day, s.starts;

-- Which sessions have nobody on the door. The thing a coordinator wants to
-- see at 5am, while there is still time to fix it.
create or replace view session_coverage
with (security_invoker = true) as
  select d.day,
         s.id    as session_id,
         s.name  as session_name,
         s.venue,
         s.starts,
         s.ends,
         count(a.volunteer_id) as volunteers,
         coalesce(
           string_agg(v.name, ', ' order by v.name) filter (where v.name is not null),
           '') as assigned_to
  from session_days d
  join sessions s on s.id = d.session_id
  left join assignments a on a.session_id = s.id and a.day = d.day
  left join volunteers  v on v.id = a.volunteer_id
  group by d.day, s.id, s.name, s.venue, s.starts, s.ends
  order by d.day, s.starts;

-- Who is missing from a session that has already run. Only live badges that
-- belong to a real participant can be absent -- an unlinked spare badge is
-- not a person.
create or replace function absentees(p_session text, p_day date)
returns table (code text, pid text, name text)
language sql stable security invoker as $$
  select p.code, p.pid, p.name
  from participants p
  where not p.void
    and p.pid is not null
    and not exists (select 1 from sessions s where s.id = p_session and s.once)
    and not exists (
      select 1 from scans s
      where s.code = p.code and s.session_id = p_session and s.day = p_day
    )
  order by p.name nulls last, p.code;
$$;
