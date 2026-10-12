-- ============================================================
-- ICON — database schema
-- Run this once in: Supabase Dashboard -> SQL Editor -> New query
-- Safe to re-run (everything is IF NOT EXISTS / idempotent).
-- ============================================================


-- ------------------------------------------------------------
-- 1. salons
-- ------------------------------------------------------------

create table if not exists public.salons (
  id                  bigint generated always as identity primary key,
  name                text not null,
  address             text,
  lat                 double precision,
  lng                 double precision,
  active_chairs       int  not null default 1,
  avg_service_minutes int  not null default 15,
  is_open             boolean not null default true,
  created_at          timestamptz not null default now()
);

-- Seed the one salon the frontend ships with (SALON_ID=1).
insert into public.salons (name, address, lat, lng, active_chairs, avg_service_minutes)
select 'ICON - Perimeter Center', '120 Perimeter Center Pl, Dunwoody, GA',
       33.9245, -84.3419, 1, 15
where not exists (select 1 from public.salons);


-- ------------------------------------------------------------
-- 2. waitlists  (the table all three pages read/write)
-- ------------------------------------------------------------

create table if not exists public.waitlists (
  id            bigint generated always as identity primary key,
  salon_id      bigint not null references public.salons(id) on delete cascade,
  customer_name text   not null check (char_length(trim(customer_name)) between 2 and 80),
  phone_number  text   not null check (phone_number ~ '^\+?[0-9]{10,15}$'),
  clip_notes    text   check (char_length(clip_notes) <= 500),
  status        text   not null default 'waiting'
                       check (status in ('waiting', 'in_chair', 'done', 'cancelled')),
  join_time     timestamptz not null default now(),
  called_at     timestamptz,
  finished_at   timestamptz
);

-- Fast lookup for the "open queue" query every page runs.
create index if not exists waitlists_queue_idx
  on public.waitlists (salon_id, status, join_time);

-- One active check-in per phone number, per salon.
-- Violating this returns Postgres error 23505, which the UI turns into
-- "That number is already on the waitlist."
create unique index if not exists waitlists_active_phone_idx
  on public.waitlists (salon_id, phone_number)
  where status in ('waiting', 'in_chair');


-- ------------------------------------------------------------
-- 3. Realtime  ** REQUIRED **
-- ------------------------------------------------------------
-- Without this, postgres_changes NEVER fires and the pages will
-- only update on the 30s fallback poll. This is the single most
-- commonly missed step.

alter table public.waitlists replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.waitlists;
exception
  when duplicate_object then null;  -- already added, fine
end $$;


-- ------------------------------------------------------------
-- 4. Row Level Security — DEV / DEMO policies
-- ------------------------------------------------------------
-- These let the app work immediately with no login, which is what
-- you want while building. They also mean anyone holding your
-- publishable key can read and modify the queue.
--
-- ⚠  Before putting this in a real salon, replace this block with
--    section 5 below.

alter table public.salons    enable row level security;
alter table public.waitlists enable row level security;

drop policy if exists "salons readable" on public.salons;
create policy "salons readable" on public.salons
  for select to anon, authenticated using (true);

drop policy if exists "dev open read"   on public.waitlists;
drop policy if exists "dev open insert" on public.waitlists;
drop policy if exists "dev open update" on public.waitlists;

create policy "dev open read" on public.waitlists
  for select to anon, authenticated using (true);

create policy "dev open insert" on public.waitlists
  for insert to anon, authenticated with check (status = 'waiting');

create policy "dev open update" on public.waitlists
  for update to anon, authenticated using (true) with check (true);

-- Note: no DELETE policy. The app never hard-deletes — "Remove" and
-- "Purge" set status to 'cancelled' so you keep your history.


-- ============================================================
-- 5. PRODUCTION policies  (commented out — enable when you add login)
-- ============================================================
-- Steps:
--   a) Supabase Dashboard -> Authentication -> Providers -> enable Email
--   b) Authentication -> Sign In / Sign Up -> turn OFF "Allow new users
--      to sign up"  (so nobody can self-register as staff)
--   c) Authentication -> Users -> "Add user" for each stylist
--   d) Insert a matching row into staff (below)
--   e) Run this block, then drop the three "dev open *" policies above
--   f) Add a session check to the top of admin.html:
--        const { data } = await ICON.db.auth.getSession();
--        if (!data.session) location.href = './login.html';
--
-- create table if not exists public.staff (
--   user_id  uuid primary key references auth.users(id) on delete cascade,
--   salon_id bigint not null references public.salons(id) on delete cascade,
--   role     text not null default 'stylist'
--            check (role in ('stylist', 'manager', 'owner'))
-- );
-- alter table public.staff enable row level security;
--
-- create policy "staff see own row" on public.staff
--   for select to authenticated using (user_id = auth.uid());
--
-- create or replace function public.is_staff_of(p_salon bigint)
-- returns boolean language sql security definer stable set search_path = public as $$
--   select exists (
--     select 1 from public.staff
--     where user_id = auth.uid() and salon_id = p_salon
--   );
-- $$;
--
-- -- Public may read only today's open rows.
-- -- Realtime filters ROWS by RLS but not COLUMNS, so anyone who can
-- -- select a row also receives phone_number over the websocket. If that
-- -- matters to you, move phone_number into its own staff-only table.
-- create policy "queue public read" on public.waitlists
--   for select to anon, authenticated
--   using (status in ('waiting','in_chair') and join_time > now() - interval '12 hours');
--
-- create policy "public check in" on public.waitlists
--   for insert to anon with check (status = 'waiting');
--
-- create policy "staff manage queue" on public.waitlists
--   for all to authenticated
--   using (public.is_staff_of(salon_id))
--   with check (public.is_staff_of(salon_id));


-- ============================================================
-- 6. Optional housekeeping
-- ============================================================
-- Auto-cancel anyone left 'waiting' overnight so the board starts clean.
-- Requires: Database -> Extensions -> enable `pg_cron`.
--
-- select cron.schedule('icon-nightly-reset', '0 4 * * *', $$
--   update public.waitlists
--      set status = 'cancelled', finished_at = now()
--    where status in ('waiting','in_chair')
--      and join_time < now() - interval '8 hours';
-- $$);


-- ------------------------------------------------------------
-- Verify
-- ------------------------------------------------------------
-- Realtime wired up? Should return one row:
--   select tablename from pg_publication_tables
--    where pubname = 'supabase_realtime' and tablename = 'waitlists';
--
-- Policies in place?
--   select policyname, cmd, roles from pg_policies where tablename = 'waitlists';
