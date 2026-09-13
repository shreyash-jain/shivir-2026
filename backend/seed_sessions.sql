-- The ten-day schedule. Run after schema.sql.
--
-- SESSION IDS ARE SHARED ACROSS DAYS. There is one `pray-am` row, not ten,
-- and the date lives on the scan (`scans.day`). `session_days` then records
-- which days each session actually runs, so arrival day and departure day
-- can differ from the eight full days in between.
--
-- That choice is what makes absentees() a two-argument lookup:
--
--     select * from absentees('pray-am', '2026-12-22');
--
-- rather than a per-day id you have to construct. If you ever need a session
-- to run at a DIFFERENT TIME on different days, it needs its own id (see
-- `session-1-short` below for the pattern) -- `sessions.starts` is a `time`
-- and holds one clock time for the whole event.
--
-- ---------------------------------------------------------------------------
-- BEFORE YOU RUN THIS, EDIT TWO THINGS:
--   1. The start date on the line marked DAY ONE.
--   2. The times below, to match the real programme. The defaults here are
--      the same seven sessions the scanner ships with, so that a phone that
--      has never been configured still agrees with the database.
-- Everything else follows from those.
-- ---------------------------------------------------------------------------

begin;

-- ------------------------------------------------------------ the sessions

insert into sessions (id, name, venue, starts, ends) values
  ('pray-am',        'Morning prayer',   'Prayer hall', '06:00', '08:00'),
  ('breakfast',      'Breakfast',        'Dining hall', '08:00', '09:30'),
  ('session-1',      'Morning session',  'Main hall',   '09:30', '12:30'),
  ('lunch',          'Lunch',            'Dining hall', '12:30', '14:00'),
  ('session-2',      'Evening session',  'Main hall',   '16:00', '18:30'),
  ('dinner',         'Dinner',           'Dining hall', '19:30', '21:00'),
  ('lights',         'Night check-in',   'Dormitory',   '22:00', '23:30'),
  -- Arrival and departure days do not follow the normal shape.
  ('arrival',        'Arrival & registration', 'Registration', '10:00', '20:00'),
  ('session-1-short','Closing session',  'Main hall',   '09:30', '11:00'),
  ('departure',      'Departure',        'Registration', '11:00', '15:00')
on conflict (id) do update
  set name   = excluded.name,
      venue  = excluded.venue,
      starts = excluded.starts,
      ends   = excluded.ends;

-- --------------------------------------------------------- which days run
--
-- Day 1 is arrival: people trickle in through the afternoon, so there is no
-- morning prayer and no morning session, but there is registration, food and
-- a night check-in.
--
-- Days 2-9 are the full programme.
--
-- Day 10 is departure: prayer, breakfast, a short closing session, lunch,
-- and then people leave. No evening session, no dinner, no night check-in.

with cal as (
  select
    d                                   as dayno,
    -- DAY ONE -- the date the first participant arrives. Edit this.
    date '2026-12-21' + (d - 1)         as day
  from generate_series(1, 10) as d
),
plan as (
  select c.day, c.dayno, s.session_id
  from cal c
  cross join lateral (
    select unnest(
      case
        when c.dayno = 1  then array['arrival','lunch','dinner','lights']
        when c.dayno = 10 then array['pray-am','breakfast','session-1-short','lunch','departure']
        else array['pray-am','breakfast','session-1','lunch','session-2','dinner','lights']
      end
    ) as session_id
  ) s
)
insert into session_days (session_id, day)
select session_id, day from plan
on conflict (session_id, day) do nothing;

commit;

-- ---------------------------------------------------------------- check it
--
-- Expect 10 days, 4 sessions on day 1, 7 on days 2-9, 5 on day 10 = 65 rows.
--
--   select day, count(*) from session_days group by day order by day;
--
-- And the schedule as a volunteer would read it:
--
--   select d.day, s.starts, s.ends, s.venue, s.name
--   from session_days d join sessions s on s.id = d.session_id
--   order by d.day, s.starts;
--
-- ---------------------------------------------------------------------------
-- Keeping the phones in step
--
-- Phones download this table once at setup ("Load from the server") and then
-- carry their own copy so they work with no signal. After editing the
-- schedule -- here or on the /admin Calendar tab -- a phone picks the change
-- up the next time it loads at base camp. A mismatch is not fatal: the scan
-- records the session id the phone chose, and a session id the database has
-- never heard of still inserts, because scans.session_id deliberately has no
-- foreign key to sessions.
--
-- This file is a starting point. Day to day, the schedule is edited on the
-- /admin page, not by re-running this.
