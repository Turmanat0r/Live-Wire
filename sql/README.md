# Database

Paste a whole file into the Supabase SQL editor and press Run. Every one of
these is safe to run twice.

## If writes ever stop working mid-event

**`supabase-rollback-open-access.sql`** — one paste, and registration, catches,
check-ins and donations all work again. Safe in any state, and it leaves the
ownership columns alone so the security files can be re-applied afterwards.

This is the only one worth knowing about while standing at a boat ramp.

## The tables and the bucket have to agree

These files do not each own a separate corner of the database. 2b and 3 set the
**table** policies; 4 sets the **storage** policies; the rollback sets both. Run
them in an order that leaves those two halves disagreeing and the app does not
fail — it half-works, which is worse, and it is the one failure this schema can
produce that nothing in the app will report.

What it looked like the first time: the rollback had been run, so the tables
were open to `anon` again, and step 4 was run afterwards on its own. Storage now
wanted an owner and the tables did not care. An angler whose phone never got an
anonymous session — a blocked CDN is enough — could then register, check in, and
have every one of those writes accepted with `owner` null. Only the photo was
refused. The app unwound the catch to avoid filing evidence-free, told them to
check a signal that was fine, and left nothing behind to find. It was spotted
because one row in `anglers` had a null `owner` and the bucket had taken no
uploads since the day step 4 was run.

## An open policy left behind beats every strict one next to it

This is the trap, and it does not look like one. **Postgres RLS policies are
permissive: they are OR-ed.** A row is allowed if *any* policy allows it. So a
single surviving

```
anglers_public_rw   ALL   {anon,authenticated}   using (true) with check (true)
```

grants everything to everybody, and the careful `anglers_insert` /
`anglers_update` / `anglers_delete` sitting beside it in the same table are
decoration. The policy list looks *more* locked down than before, because there
are more rows in it.

**How it gets left behind:** `supabase-setup.sql` drops only the `*_public_rw`
policies before recreating them. It never drops the granular ones. So running
setup on a project that has already had 2b applied leaves BOTH sets in place,
and open access wins. That file is for a new project from nothing; on a live one
it silently undoes step 2b.

So the check is not "do the strict policies exist" — it is **"is there anything
open still here"**. Run this after any of these files:

```sql
select 'director accounts'        as check,
       count(*) filter (where (raw_app_meta_data->>'director') = 'true')::text as value
  from auth.users
union all
select 'anonymous devices',
       count(*) filter (where is_anonymous)::text
  from auth.users
union all
select 'open-access policies left',
       count(*)::text
  from pg_policies where policyname like '%public%rw%'
union all
select 'step 3 co_owners clause',
       case when exists (select 1 from pg_policies
                          where schemaname = 'public'
                            and tablename  = 'anglers'
                            and policyname = 'anglers_update'
                            and qual like '%co_owners%')
            then 'yes' else 'NO - re-run step 3' end;
```

| check | must be |
|---|---|
| director accounts | `1` — anything else and you have locked yourself out |
| anonymous devices | 1 or more |
| open-access policies left | **`0`** |
| step 3 co_owners clause | `yes` — or a claimed second device still cannot write |

`open-access policies left` is the one that matters most and the one nobody
thinks to look for.

**Last run against production: 2026-09-21.** Director accounts 1, anonymous
devices 75, open-access policies left 0, step 3 co_owners clause yes - every
one as it must be. The ownership policies are on, so a passcode opens the
director panel but the server refuses its writes; only the director's sign-in
is accepted.

There is also a read-only smoke test that needs no SQL editor at all. Ask the
API for `signals` with the plain anon key: enforced, it returns `[]`, because an
angler's position is director-and-owner only. Open, it hands back the whole
table.

```
curl -s "$SUPABASE_URL/rest/v1/signals?select=id" \
     -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY"
```

**It only means anything when the table has rows in it.** An empty `signals`
returns `[]` whether the policies are enforced or wide open, so on a freshly
cleared project — or before anybody has switched a beacon on — this test passes
for the wrong reason and proves nothing. Check the count first:

```sql
select count(*) from public.signals;
```

Zero, and skip it: the `pg_policies` query above is the real check and does not
care whether there is any data. This one is for a running event, where it takes
five seconds from a phone and needs no database access at all.

Then confirm nothing is stranded:

```sql
select count(*) from public.anglers where owner is null;
select count(*) from public.catches where owner is null;
```

Rows written while a device was on the shared key have a null `owner`, and under
enforced policies only the director can touch them. The angler's own way back is
**Sign in to my entry** on the register screen — their board code and the phone
on the entry — which calls `claim_entry()` and adds their device to `co_owners`.
That works on a null-owner row, which is the whole reason it is security
definer.

## Setting up a project from nothing

In this order. The Montana Kayak Walleye Open project has had all of them run
already — this is the list for a **new** Supabase project, which is what a
second organizer running their own tournament would need.

| # | File | What it does |
|---|---|---|
| 1 | `supabase-setup.sql` | The seven tables, open access, the photo bucket |
| 2 | `supabase-step2a-ownership-columns.sql` | Adds `owner` columns. Changes no behaviour |
| 3 | `supabase-step2b-enforce-policies.sql` | Turns ownership on. **Read the gate at the top first** |
| 4 | `supabase-one-entry-per-person.sql` | Unique name, phone and board code |
| 5 | `supabase-step3-shared-devices.sql` | Lets one angler use one entry from several devices |
| 6 | `supabase-step4-photo-integrity.sql` | Stops a catch photo being swapped after it is filed |
| 7 | `supabase-step5-director-fields-and-beacons.sql` | Keeps review, fees, disqualification and codes the director's; lets the field see a beacon |

Between 2 and 3 there is a manual step, described in 3: enable anonymous
sign-ins, open the app once so a device actually exists, and create the
director account with `{"director": true}` on its **app_metadata**. Running 3
before both of those exist locks everybody out, including you.

### 2a is not a one-time step — re-run it whenever a table is added

`supabase-step2a-ownership-columns.sql` names its tables one per line, and step
2b writes policies against `owner` on every one of them. Add a table to
`supabase-setup.sql` later — side bets did exactly this — and 2a does not know
about it until it is re-run. Then 2b dies partway with:

```
ERROR: 42703: column "owner" does not exist
```

The SQL editor runs the paste as one transaction, so a failure like that rolls
the **whole file** back and leaves the database exactly as it was. Nothing is
half-applied. Re-run 2a, then 2b again.

Cheapest habit: run 2a immediately before 2b, every time. It is `add column if
not exists` throughout, so on tables that already have it the cost is nothing.
To see which tables are short:

```sql
select t.tablename
  from pg_tables t
 where t.schemaname = 'public'
   and t.tablename <> 'config'
   and not exists (select 1 from information_schema.columns c
                    where c.table_schema = 'public'
                      and c.table_name   = t.tablename
                      and c.column_name  = 'owner');
```

`config` is excluded on purpose: it is director-only and none of its policies
read `owner`.

## Step 5: what only the director decides

Before step 5, an angler owned their whole entry and their whole catch, so
their own device could approve a catch, change a reviewed length, mark their
fee paid or lift a disqualification - and a phone that had not synced yet could
do the last one by accident, by writing back its stale copy on the next
check-in. A raised beacon was also invisible to every other angler.

Step 5 lets an angler's device change only what the app itself changes: their
check-ins, and the length of a catch that is still pending. Everything else
keeps its value, and a reviewed catch refuses changes with error 42501, which
the app already reports as "the tournament server refused this". The director,
the SQL editor and `claim_entry()` are not affected.

It finishes by listing what it created. Three rows means it worked:

```
kind     name                            on_table
policy   signals_read_beacons            signals
trigger  anglers_guard_director_fields   anglers
trigger  catches_guard_review            catches
```

## Housekeeping

`reset-test-data.sql` empties every table in every event. The director portal
now does this per-event — Director → Event → **Clear data**, or **Delete** for
an event added there — which is almost always what you actually want. This file
is the blunt version for starting a project over completely.

## Why the applied files are still here

Running them once does not make them disposable: they are how a database gets
back to this shape, whether that is a second organizer's project or this one
after something goes wrong. They cost nothing to keep and cannot be
reconstructed from the app.
