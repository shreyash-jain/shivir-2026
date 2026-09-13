-- Attendance backend. Paste into the Supabase SQL editor.
--
-- Two kinds of client talk to this database and they get very different
-- powers:
--
--   Volunteer phones  hold the publishable key and run as `anon`. They may
--                     insert scans and insert badge links, and read what a
--                     phone must know to work offline: the session schedule,
--                     the duty roster, and volunteer names. They cannot read
--                     the participant roll and cannot update or delete
--                     anything. A leaked key cannot expose who is attending,
--                     erase a record, or change the schedule.
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
  ends    time not null
);

-- Session ids are shared across the ten days and the date lives on the scan.
-- This table says which days each session actually runs, so that day 1 and
-- day 10 can differ and absentees() is never asked about a session that did
-- not happen. Seeded by seed_sessions.sql.
create table if not exists session_days (
  session_id text not null references sessions(id) on delete cascade,
  day        date not null,
  primary key (session_id, day)
);

-- Who is holding each phone. The super admin maintains this; phones download
-- it once and a volunteer picks their own name off the cached list at the
-- start of a shift. No logins: these are shared handsets and a password reset
-- at 6am in a field is not a support model.
create table if not exists volunteers (
  id         text primary key,             -- short, stable, e.g. 'v-anjali'
  name       text not null,
  phone      text,                         -- for the shift coordinator only
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

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

-- Phones may add scans and badge links and nothing else. No select, no
-- update, no delete.
drop policy if exists "devices insert scans" on scans;
create policy "devices insert scans"
  on scans for insert to anon
  with check (true);

drop policy if exists "devices insert links" on badge_links;
create policy "devices insert links"
  on badge_links for insert to anon
  with check (true);

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

-- Phones need volunteer NAMES so the person holding one can pick themselves
-- off a list. They do not need phone numbers. Rather than open the table, a
-- view exposes exactly the two columns required; it runs as its owner, so it
-- reads through the RLS that keeps the base table shut.
create or replace view volunteer_roster as
  select id, name from volunteers where active;

grant select on volunteer_roster to anon, authenticated;

-- participants has RLS on and deliberately no anon policy, so the key
-- cannot read names. Phones get the roll from the bundled codes.csv instead.
-- The foreign key on scans.code still rejects codes that were never issued.
-- volunteers is shut for the same reason; volunteer_roster is the narrow
-- window into it.

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
    and not exists (
      select 1 from scans s
      where s.code = p.code and s.session_id = p_session and s.day = p_day
    )
  order by p.name nulls last, p.code;
$$;
