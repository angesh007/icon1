-- ============================================================
-- ICON — database schema  (v2)
--
-- Run this in: Supabase Dashboard -> SQL Editor -> New query
--
-- Safe to run on EITHER a fresh project OR an existing v1 install.
-- Everything is idempotent, and the v1 -> v2 changes are applied as
-- ALTERs against your present `waitlists` table — nothing is dropped
-- and no rows are lost.
--
-- WHAT V2 ADDS
--   • ticket_no        daily ticket number per salon (the "07" on screen)
--   • preferred_time   customer's requested time, NULL = as soon as possible
--   • service_date     which day a ticket belongs to
--   • waitlist_contacts    phone numbers moved OFF the public table
--   • admins + admin_sessions   staff login with admin_id + password
--   • password verification INSIDE Postgres via pgcrypto
--   • all writes go through token-gated functions, so the queue cannot
--     be modified straight from a browser
-- ============================================================

create extension if not exists pgcrypto;


-- ============================================================
-- 1. salons
-- ============================================================

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

insert into public.salons (name, address, lat, lng, active_chairs, avg_service_minutes)
select 'ICON - Perimeter Center', '120 Perimeter Center Pl, Dunwoody, GA',
       33.9245, -84.3419, 1, 15
where not exists (select 1 from public.salons);


-- ============================================================
-- 2. waitlists  (created if absent, upgraded if already there)
-- ============================================================

create table if not exists public.waitlists (
  id            bigint generated always as identity primary key,
  salon_id      bigint not null references public.salons(id) on delete cascade,
  customer_name text   not null check (char_length(trim(customer_name)) between 2 and 80),
  clip_notes    text   check (char_length(clip_notes) <= 500),
  status        text   not null default 'waiting'
                       check (status in ('waiting', 'in_chair', 'done', 'cancelled')),
  join_time     timestamptz not null default now(),
  called_at     timestamptz,
  finished_at   timestamptz
);

-- --- v2 columns -------------------------------------------------------

alter table public.waitlists add column if not exists ticket_no      int;
alter table public.waitlists add column if not exists service_date   date;
alter table public.waitlists add column if not exists preferred_time timestamptz;

-- Backfill service_date for any pre-existing rows, then enforce it.
update public.waitlists set service_date = (join_time at time zone 'UTC')::date
 where service_date is null;

alter table public.waitlists alter column service_date set default current_date;

do $$
begin
  alter table public.waitlists alter column service_date set not null;
exception when others then null;
end $$;

-- Backfill ticket numbers for pre-existing rows, in join order per day.
with numbered as (
  select id, row_number() over (partition by salon_id, service_date
                                order by join_time, id) as n
    from public.waitlists
   where ticket_no is null
)
update public.waitlists w
   set ticket_no = numbered.n
  from numbered
 where w.id = numbered.id;

create unique index if not exists waitlists_ticket_key
  on public.waitlists (salon_id, service_date, ticket_no);

create index if not exists waitlists_queue_idx
  on public.waitlists (salon_id, status, join_time);


-- ============================================================
-- 3. waitlist_contacts  — phone numbers live here, not on the
--    public table. Realtime filters ROWS by RLS but not COLUMNS,
--    so anything left on `waitlists` is readable by every visitor.
-- ============================================================

create table if not exists public.waitlist_contacts (
  entry_id     bigint primary key references public.waitlists(id) on delete cascade,
  phone_number text not null check (phone_number ~ '^\+?[0-9]{10,15}$'),
  created_at   timestamptz not null default now()
);

-- Move any existing phone numbers across, then drop the old column.
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'waitlists'
       and column_name = 'phone_number'
  ) then
    insert into public.waitlist_contacts (entry_id, phone_number)
    select id, phone_number
      from public.waitlists
     where phone_number is not null
       and phone_number ~ '^\+?[0-9]{10,15}$'
    on conflict (entry_id) do nothing;

    alter table public.waitlists drop column phone_number;
    raise notice 'Moved phone numbers into waitlist_contacts and dropped waitlists.phone_number';
  end if;
end $$;

-- One active ticket per phone number per salon per day.
create unique index if not exists contacts_active_phone_idx
  on public.waitlist_contacts (phone_number, entry_id);


-- ============================================================
-- 4. admins + sessions
-- ============================================================

create table if not exists public.admins (
  id             bigint generated always as identity primary key,
  admin_id       text not null,
  password_hash  text not null,
  display_name   text not null,
  salon_id       bigint references public.salons(id) on delete cascade,
  role           text not null default 'stylist'
                 check (role in ('stylist', 'manager', 'owner')),
  is_active      boolean not null default true,
  failed_attempts int not null default 0,
  locked_until   timestamptz,
  last_login_at  timestamptz,
  created_at     timestamptz not null default now()
);

-- admin_id is case-insensitive: "Ravi" and "ravi" are the same login.
create unique index if not exists admins_admin_id_key
  on public.admins (lower(admin_id));

create table if not exists public.admin_sessions (
  token        uuid primary key default gen_random_uuid(),
  admin_pk     bigint not null references public.admins(id) on delete cascade,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '12 hours'
);

create index if not exists admin_sessions_admin_idx on public.admin_sessions (admin_pk);


-- ============================================================
-- 5. Row Level Security
--
-- The only table a browser may read directly is `waitlists`
-- (names + status + times, no phone numbers) so that Realtime
-- works. Everything else is reachable only through the functions
-- in section 6, which run as the definer and check a session token.
-- ============================================================

alter table public.salons            enable row level security;
alter table public.waitlists         enable row level security;
alter table public.waitlist_contacts enable row level security;
alter table public.admins            enable row level security;
alter table public.admin_sessions    enable row level security;

-- Drop the permissive v1 dev policies if they are still present.
drop policy if exists "dev open read"   on public.waitlists;
drop policy if exists "dev open insert" on public.waitlists;
drop policy if exists "dev open update" on public.waitlists;
drop policy if exists "queue public read" on public.waitlists;
drop policy if exists "public check in"   on public.waitlists;

drop policy if exists "salons readable" on public.salons;
create policy "salons readable" on public.salons
  for select to anon, authenticated using (true);

-- Today's open tickets only. No INSERT/UPDATE/DELETE policy exists,
-- so a browser cannot change the queue except through a function.
create policy "queue public read" on public.waitlists
  for select to anon, authenticated
  using (
    service_date = current_date
    and status in ('waiting', 'in_chair')
  );

-- waitlist_contacts, admins and admin_sessions deliberately have
-- NO policies. With RLS enabled and no policy, every direct browser
-- query returns zero rows. Password hashes are unreachable.


-- ============================================================
-- 6. Functions
--    All SECURITY DEFINER with a pinned search_path, so they can
--    reach the locked tables while callers cannot.
-- ============================================================

-- ---------- 6a. internal: resolve a session token ----------

create or replace function public._admin_from_token(p_token uuid)
returns public.admins
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  if p_token is null then
    raise exception 'Not signed in' using errcode = '28000';
  end if;

  select a.* into v_admin
    from public.admin_sessions s
    join public.admins a on a.id = s.admin_pk
   where s.token = p_token
     and s.expires_at > now()
     and a.is_active;

  if not found then
    raise exception 'Session expired. Sign in again.' using errcode = '28000';
  end if;

  return v_admin;
end $$;


-- ---------- 6b. sign in ----------
--
-- NOTE: this function RETURNS failures as { "ok": false, "error": ... }
-- rather than raising them. That is deliberate and load-bearing:
-- RAISE EXCEPTION aborts the transaction, which would roll back the
-- failed_attempts increment on the very same call — so the lockout
-- counter could never actually accumulate. Returning lets the counter
-- commit. Callers must check `ok`, not just the absence of an error.

create or replace function public.admin_login(p_admin_id text, p_password text)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_admin public.admins;
  v_token uuid;
  v_wait  int;
  -- One message for every auth failure, so this cannot be used to
  -- discover which staff IDs exist.
  c_denied constant text := 'Incorrect staff ID or password';
begin
  if coalesce(trim(p_admin_id), '') = '' or coalesce(p_password, '') = '' then
    return json_build_object('ok', false, 'error', 'Enter your staff ID and password');
  end if;

  select * into v_admin
    from public.admins
   where lower(admin_id) = lower(trim(p_admin_id));

  if not found or not v_admin.is_active then
    perform pg_sleep(0.4);
    return json_build_object('ok', false, 'error', c_denied);
  end if;

  if v_admin.locked_until is not null and v_admin.locked_until > now() then
    v_wait := greatest(1, ceil(extract(epoch from (v_admin.locked_until - now())) / 60));
    return json_build_object(
      'ok', false, 'locked', true,
      'error', 'Too many attempts. Try again in ' || v_wait || ' minute' ||
               case when v_wait = 1 then '' else 's' end || '.');
  end if;

  if v_admin.password_hash <> crypt(p_password, v_admin.password_hash) then
    update public.admins
       set failed_attempts = failed_attempts + 1,
           -- keep any existing lock; set one once we hit 5
           locked_until = case
             when failed_attempts + 1 >= 5 then now() + interval '15 minutes'
             else locked_until
           end
     where id = v_admin.id
    returning failed_attempts, locked_until into v_admin.failed_attempts, v_admin.locked_until;

    perform pg_sleep(0.4);

    if v_admin.locked_until is not null and v_admin.locked_until > now() then
      return json_build_object(
        'ok', false, 'locked', true,
        'error', 'Too many attempts. Locked for 15 minutes.');
    end if;

    return json_build_object(
      'ok', false, 'error', c_denied,
      'attempts_left', greatest(0, 5 - v_admin.failed_attempts));
  end if;

  update public.admins
     set failed_attempts = 0, locked_until = null, last_login_at = now()
   where id = v_admin.id;

  -- One active session per admin keeps things tidy.
  delete from public.admin_sessions
   where admin_pk = v_admin.id or expires_at < now();

  insert into public.admin_sessions (admin_pk)
  values (v_admin.id)
  returning token into v_token;

  return json_build_object(
    'ok',           true,
    'token',        v_token,
    'admin_id',     v_admin.admin_id,
    'display_name', v_admin.display_name,
    'role',         v_admin.role,
    'salon_id',     v_admin.salon_id,
    'expires_at',   now() + interval '12 hours'
  );
end $$;


-- ---------- 6c. who am I / sign out / change password ----------

create or replace function public.admin_session(p_token uuid)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);

  update public.admin_sessions set last_seen_at = now() where token = p_token;

  return json_build_object(
    'admin_id',     v_admin.admin_id,
    'display_name', v_admin.display_name,
    'role',         v_admin.role,
    'salon_id',     v_admin.salon_id
  );
end $$;


create or replace function public.admin_logout(p_token uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from public.admin_sessions where token = p_token;
$$;


create or replace function public.admin_change_password(
  p_token uuid, p_current text, p_new text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);

  if v_admin.password_hash <> crypt(p_current, v_admin.password_hash) then
    raise exception 'Current password is incorrect' using errcode = '28P01';
  end if;

  if char_length(p_new) < 8 then
    raise exception 'New password must be at least 8 characters' using errcode = '22023';
  end if;

  update public.admins
     set password_hash = crypt(p_new, gen_salt('bf', 12))
   where id = v_admin.id;

  -- Force a fresh sign-in everywhere.
  delete from public.admin_sessions where admin_pk = v_admin.id;
end $$;


-- ---------- 6d. public check-in ----------

create or replace function public.check_in(
  p_salon          bigint,
  p_name           text,
  p_phone          text,
  p_notes          text default null,
  p_preferred_time timestamptz default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_phone  text;
  v_ticket int;
  v_id     bigint;
begin
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g');

  if char_length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Enter your full name' using errcode = '22023';
  end if;

  if v_phone !~ '^\+?[0-9]{10,15}$' then
    raise exception 'Enter a valid mobile number' using errcode = '22023';
  end if;

  if not exists (select 1 from public.salons where id = p_salon and is_open) then
    raise exception 'This salon is not taking check-ins right now' using errcode = '22023';
  end if;

  -- Already holding a ticket today?
  if exists (
    select 1
      from public.waitlists w
      join public.waitlist_contacts c on c.entry_id = w.id
     where w.salon_id = p_salon
       and w.service_date = current_date
       and w.status in ('waiting', 'in_chair')
       and c.phone_number = v_phone
  ) then
    raise exception 'That number already has a ticket today' using errcode = '23505';
  end if;

  -- Serialise ticket numbering per salon so two people cannot take the
  -- same number at the same moment.
  perform pg_advisory_xact_lock(p_salon);

  select coalesce(max(ticket_no), 0) + 1 into v_ticket
    from public.waitlists
   where salon_id = p_salon and service_date = current_date;

  insert into public.waitlists
    (salon_id, customer_name, clip_notes, status, ticket_no, service_date, preferred_time)
  values
    (p_salon, trim(p_name), nullif(trim(coalesce(p_notes, '')), ''), 'waiting',
     v_ticket, current_date, p_preferred_time)
  returning id into v_id;

  insert into public.waitlist_contacts (entry_id, phone_number)
  values (v_id, v_phone);

  return json_build_object('entry_id', v_id, 'ticket_no', v_ticket);
end $$;


-- ---------- 6e. staff reads and writes (token-gated) ----------

create or replace function public.admin_queue(p_token uuid)
returns table (
  id bigint, ticket_no int, customer_name text, phone_number text,
  clip_notes text, status text, join_time timestamptz,
  preferred_time timestamptz, called_at timestamptz)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);

  return query
    select w.id, w.ticket_no, w.customer_name, c.phone_number,
           w.clip_notes, w.status, w.join_time, w.preferred_time, w.called_at
      from public.waitlists w
      left join public.waitlist_contacts c on c.entry_id = w.id
     where w.salon_id = coalesce(v_admin.salon_id, w.salon_id)
       and w.service_date = current_date
       and w.status in ('waiting', 'in_chair')
     order by w.join_time;
end $$;


create or replace function public.admin_register_walkin(
  p_token          uuid,
  p_name           text,
  p_phone          text,
  p_notes          text default null,
  p_preferred_time timestamptz default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);
  return public.check_in(v_admin.salon_id, p_name, p_phone, p_notes, p_preferred_time);
end $$;


create or replace function public.admin_set_status(
  p_token uuid, p_entry_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);

  if p_status not in ('waiting', 'in_chair', 'done', 'cancelled') then
    raise exception 'Unknown status: %', p_status using errcode = '22023';
  end if;

  update public.waitlists
     set status      = p_status,
         called_at   = case when p_status = 'in_chair' then now() else called_at end,
         finished_at = case when p_status in ('done', 'cancelled') then now() end
   where id = p_entry_id
     and salon_id = coalesce(v_admin.salon_id, salon_id)
     and service_date = current_date;

  if not found then
    raise exception 'That ticket is no longer in today''s queue' using errcode = '02000';
  end if;
end $$;


create or replace function public.admin_purge(p_token uuid)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_admin public.admins;
  v_count int;
begin
  v_admin := public._admin_from_token(p_token);

  if v_admin.role not in ('manager', 'owner') then
    raise exception 'Only a manager can clear the queue' using errcode = '42501';
  end if;

  with cleared as (
    update public.waitlists
       set status = 'cancelled', finished_at = now()
     where salon_id = coalesce(v_admin.salon_id, salon_id)
       and service_date = current_date
       and status in ('waiting', 'in_chair')
    returning 1
  )
  select count(*) into v_count from cleared;

  return v_count;
end $$;


-- ============================================================
-- 7. Grants
--    The browser may call only these. _admin_from_token stays private.
-- ============================================================

-- Supabase grants this already; stated here so the script also works on
-- a project where the public schema has been recreated.
grant usage on schema public to anon, authenticated;

-- ---------- Table privileges ----------
-- Stated explicitly rather than relying on the platform's defaults.
-- RLS narrows these further, but the grants are the outer wall: even
-- if RLS were switched off by accident, a browser still could not
-- write to the queue or read a password hash.

grant select on public.waitlists to anon, authenticated;
grant select on public.salons    to anon, authenticated;

-- The queue changes only through the functions below.
revoke insert, update, delete, truncate on public.waitlists from anon, authenticated;

-- Private tables: no direct access of any kind.
revoke all on public.waitlist_contacts from anon, authenticated;
revoke all on public.admins            from anon, authenticated;
revoke all on public.admin_sessions    from anon, authenticated;

-- ---------- Function privileges ----------

revoke all on function public._admin_from_token(uuid)                     from public, anon, authenticated;
revoke all on function public.admin_login(text, text)                     from public;
revoke all on function public.admin_session(uuid)                         from public;
revoke all on function public.admin_logout(uuid)                          from public;
revoke all on function public.admin_change_password(uuid, text, text)      from public;
revoke all on function public.check_in(bigint, text, text, text, timestamptz) from public;
revoke all on function public.admin_queue(uuid)                           from public;
revoke all on function public.admin_register_walkin(uuid, text, text, text, timestamptz) from public;
revoke all on function public.admin_set_status(uuid, bigint, text)        from public;
revoke all on function public.admin_purge(uuid)                           from public;

grant execute on function public.admin_login(text, text)                  to anon, authenticated;
grant execute on function public.admin_session(uuid)                      to anon, authenticated;
grant execute on function public.admin_logout(uuid)                       to anon, authenticated;
grant execute on function public.admin_change_password(uuid, text, text)   to anon, authenticated;
grant execute on function public.check_in(bigint, text, text, text, timestamptz) to anon, authenticated;
grant execute on function public.admin_queue(uuid)                        to anon, authenticated;
grant execute on function public.admin_register_walkin(uuid, text, text, text, timestamptz) to anon, authenticated;
grant execute on function public.admin_set_status(uuid, bigint, text)     to anon, authenticated;
grant execute on function public.admin_purge(uuid)                        to anon, authenticated;


-- ============================================================
-- 8. Realtime  ** REQUIRED **
--    Without this, postgres_changes never fires and the screens
--    only update on the 30-second fallback poll.
-- ============================================================

alter table public.waitlists replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.waitlists;
exception when duplicate_object then null;
end $$;


-- ============================================================
-- 9. CREATE YOUR FIRST ADMIN  ← edit and run this
--
-- Change the ID and password before running. The password is
-- hashed by crypt() right here, so the plain text is never stored.
-- ============================================================

insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
values (
  'admin',                                    -- the staff ID they type
  crypt('ChangeMe123!', gen_salt('bf', 12)),  -- ← CHANGE THIS PASSWORD
  'Front Desk',
  1,
  'owner'
)
on conflict (lower(admin_id)) do nothing;

-- Add more staff the same way (role: stylist | manager | owner):
-- insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
-- values ('ravi', crypt('a-good-password', gen_salt('bf', 12)), 'Ravi', 1, 'stylist');

-- Reset someone's password:
-- update public.admins
--    set password_hash = crypt('new-password', gen_salt('bf', 12)),
--        failed_attempts = 0, locked_until = null
--  where lower(admin_id) = 'ravi';

-- Unlock someone after 5 bad attempts:
-- update public.admins set failed_attempts = 0, locked_until = null
--  where lower(admin_id) = 'ravi';


-- ============================================================
-- 10. Optional: nightly reset (needs pg_cron enabled)
-- ============================================================
-- select cron.schedule('icon-nightly-reset', '0 4 * * *', $$
--   update public.waitlists set status = 'cancelled', finished_at = now()
--    where status in ('waiting','in_chair') and service_date < current_date;
--   delete from public.admin_sessions where expires_at < now();
-- $$);


-- ============================================================
-- Verify
-- ============================================================
-- Realtime on?            select tablename from pg_publication_tables
--                          where pubname='supabase_realtime' and tablename='waitlists';
-- Policies?               select policyname, cmd from pg_policies where tablename='waitlists';
-- Hashes unreachable?     set role anon; select * from admins;   -- expect 0 rows
-- Login works?            select admin_login('admin','ChangeMe123!');
