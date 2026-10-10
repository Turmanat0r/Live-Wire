-- Step 5: what only the director decides stays the director's, and a beacon
-- reaches the whole field.
--
-- Paste the whole file into the Supabase SQL editor and press Run. Safe to run
-- twice. Run it after steps 2a, 2b, 3 and 4, which this project already has.
--
-- WHAT WAS WRONG
--
-- 1. An angler could approve their own catch. The review status and the length
--    live inside the same record the angler owns, and the update policy lets
--    the owner rewrite all of it. The app never offers that, but anyone with
--    the public source and their own device's session could send it straight
--    to the database. The same was true of an angler's own entry: they could
--    mark their fee paid, lift their own disqualification, or change their
--    board code.
--
--    It also happened by accident. A phone that had not yet synced the
--    director's change wrote back its stale copy of the whole record on the
--    next check-in, so a disqualification made a few seconds earlier could be
--    silently undone by the angler checking out.
--
-- 2. A beacon did not reach the field. The beacon screen tells an angler in
--    trouble that "the director and the whole field can see you", but the
--    signals table was readable only by the director and the angler, so no
--    other kayak ever saw it.
--
-- WHAT THIS DOES
--
-- From an angler's phone - signed in anonymously or by the shared key, not as
-- the director - the database now accepts exactly what the app sends and
-- nothing more:
--
--   anglers  registering: the fee starts unconfirmed and nobody starts
--            disqualified, whatever was sent. Afterwards: check-ins and
--            check-outs only. Every other field keeps the value it had, so a
--            stale copy can no longer overwrite the director. Removing an
--            entry is the director's job.
--   catches  filing: always pending, with no review on it. While pending: the
--            length may change, and the catch may be withdrawn. Once reviewed:
--            nothing, and the phone is told why (error 42501, which the app
--            already reports as "the tournament server refused this").
--   signals  any signed-in device can read a raised beacon. Ordinary positions
--            stay director-and-owner only.
--
-- The director (a signed-in account with {"director": true} on app_metadata),
-- the SQL editor, the table editor and server functions such as claim_entry()
-- are not affected at all.
--
-- The emergency rollback (supabase-rollback-open-access.sql) leaves these in
-- place, and that is fine: they refuse nothing the app itself ever sends.

-- ---- anglers ----------------------------------------------------------------

create or replace function public.guard_angler_director_fields()
returns trigger
language plpgsql
set search_path = ''
as $guard$
begin
  -- Only the app's own roles are anglers. Everything else is the director at
  -- the dashboard or a server function, and passes untouched.
  if current_user not in ('anon', 'authenticated')
     or coalesce((auth.jwt() -> 'app_metadata' ->> 'director') = 'true', false) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.data := (new.data - 'disqualified' - 'dqReason' - 'dqAt')
                || jsonb_build_object('pending', true);
    new.co_owners := '{}';
    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Only the director can remove an entry.'
      using errcode = '42501';
  end if;

  -- UPDATE. Checking in and out is the one change an angler makes to an entry.
  if new.data ? 'checkins' then
    new.data := old.data || jsonb_build_object('checkins', new.data -> 'checkins');
  else
    new.data := old.data;
  end if;
  new.owner := old.owner;
  new.co_owners := old.co_owners;
  return new;
end;
$guard$;

drop trigger if exists anglers_guard_director_fields on public.anglers;
create trigger anglers_guard_director_fields
  before insert or update or delete on public.anglers
  for each row execute function public.guard_angler_director_fields();


-- ---- catches ----------------------------------------------------------------

create or replace function public.guard_catch_review()
returns trigger
language plpgsql
set search_path = ''
as $guard$
begin
  if current_user not in ('anon', 'authenticated')
     or coalesce((auth.jwt() -> 'app_metadata' ->> 'director') = 'true', false) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op = 'INSERT' then
    -- A filed catch is pending, whatever was sent. Note this also runs for the
    -- insert half of an upsert of an existing catch; the update below then
    -- decides what actually changes.
    new.data := (new.data - 'aiReview') || jsonb_build_object('status', 'pending');
    new.co_owners := '{}';
    return new;
  end if;

  if coalesce(old.data ->> 'status', 'pending') <> 'pending' then
    raise exception 'This catch has already been reviewed, so only the director can change it.'
      using errcode = '42501';
  end if;

  -- Withdrawing a pending catch.
  if tg_op = 'DELETE' then return old; end if;

  -- UPDATE of a pending catch. The length is the one thing an angler may fix.
  if new.data ? 'length' then
    new.data := old.data || jsonb_build_object('length', new.data -> 'length');
  else
    new.data := old.data;
  end if;
  new.owner := old.owner;
  new.co_owners := old.co_owners;
  return new;
end;
$guard$;

drop trigger if exists catches_guard_review on public.catches;
create trigger catches_guard_review
  before insert or update or delete on public.catches
  for each row execute function public.guard_catch_review();


-- ---- signals: beacons -------------------------------------------------------
-- Policies are OR-ed, so this adds raised beacons to what signals_read already
-- allows. A position with no beacon up is still the director's and the
-- angler's only.

drop policy if exists signals_read_beacons on public.signals;
create policy signals_read_beacons on public.signals
  for select to authenticated
  using ((data ->> 'beacon') = 'true');


-- ---- check ------------------------------------------------------------------
-- Three rows: two triggers and the beacon policy.

select 'trigger' as kind, tgname::text as name, tgrelid::regclass::text as on_table
  from pg_trigger
 where tgname in ('anglers_guard_director_fields', 'catches_guard_review')
union all
select 'policy', policyname::text, tablename::text
  from pg_policies
 where schemaname = 'public' and policyname = 'signals_read_beacons'
order by 1, 2;
