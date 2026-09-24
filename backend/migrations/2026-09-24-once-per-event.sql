-- Once-per-event sessions: certificate distribution, kit handout, anything a
-- person receives exactly once however many days the desk is open for.
--
-- Paste into the Supabase SQL editor. Re-runnable. Also folded into
-- schema.sql, so a fresh project gets it from there.
--
-- WHY THIS EXISTS
-- An ordinary session is de-duplicated on badge|session|day: right for
-- attendance, wrong for a certificate. Someone collecting on Tuesday could be
-- recorded again on Thursday, and a reissued badge (one participant has had
-- five) could collect once per badge. A once-per-event session is instead
-- de-duplicated on the PERSON: participant id | session, across all days.

-- ------------------------------------------------------------ the flag
alter table sessions add column if not exists once boolean not null default false;

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

drop policy if exists "organisers read once conflicts" on once_conflicts;
create policy "organisers read once conflicts"
  on once_conflicts for select to authenticated using (is_organiser());
drop policy if exists "organisers clear once conflicts" on once_conflicts;
create policy "organisers clear once conflicts"
  on once_conflicts for delete to authenticated using (is_organiser());

-- ------------------------------------------------------------ ingestion
-- The server decides the de-duplication key for once sessions, not the phone.
-- An old APK, or a phone with a stale session list, would otherwise send the
-- per-day key and let a second certificate through.
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
revoke all on function ingest_scans(jsonb) from public;
grant execute on function ingest_scans(jsonb) to anon, authenticated;

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

-- ------------------------------------------------------------ reporting
-- Attendance views and absentees() ignore once sessions: a certificate desk
-- is not a session anyone can be "absent" from on a given day.
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
