-- ============================================================
-- ICON — schema v3
--
-- Run in: Supabase Dashboard -> SQL Editor -> New query
-- Safe on a fresh project, a v1 install, or a v2 install.
-- Idempotent: re-running changes nothing.
--
-- WHAT V3 ADDS
--   • many shops in one deployment  (salons.slug, reached as /?shop=slug)
--   • services with an audience     (men / women / kids / unisex) + price
--   • staff (barbers, beauticians) the owner manages
--   • opening hours per weekday + one-off closures
--   • appointments: future bookings on a calendar, alongside the queue
--   • available_slots(): real availability from hours, staff and bookings
--   • phone numbers are now OPTIONAL (per-shop toggle)
--   • owner CRUD functions for services, staff, hours and shop settings
-- ============================================================

set search_path = public, extensions;

create schema if not exists extensions;

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pgcrypto') then
    begin
      create extension pgcrypto with schema extensions;
    exception when others then
      create extension pgcrypto;
    end;
  end if;
end $$;

grant usage on schema extensions to anon, authenticated;


-- ============================================================
-- 1. salons  — now multi-tenant
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

alter table public.salons add column if not exists slug           text;
alter table public.salons add column if not exists kind           text;
alter table public.salons add column if not exists phone_required boolean not null default false;
alter table public.salons add column if not exists slot_minutes   int not null default 30;
alter table public.salons add column if not exists lead_minutes   int not null default 30;
alter table public.salons add column if not exists horizon_days   int not null default 30;

-- A column default does not touch existing rows, so shops created under
-- v3.0 would stay on the old 14-day window. Lift only those still sitting
-- on that exact default; anything an owner has deliberately set is left be.
update public.salons set horizon_days = 30 where horizon_days = 14;
alter table public.salons add column if not exists currency       text not null default '₹';
alter table public.salons add column if not exists contact_phone  text;

-- kind is a label for the customer screen, not a feature switch:
-- both the queue and the calendar are available to every shop.
-- Re-created rather than added, so an existing v3 install picks up the
-- new values instead of silently keeping the narrower rule.
alter table public.salons drop constraint if exists salons_kind_chk;
alter table public.salons add constraint salons_kind_chk
  check (kind is null or kind in ('barber', 'salon', 'nails', 'spa', 'carwash'));

insert into public.salons (name, address, lat, lng, active_chairs, avg_service_minutes)
select 'ICON - Perimeter Center', '120 Perimeter Center Pl, Dunwoody, GA',
       33.9245, -84.3419, 1, 15
where not exists (select 1 from public.salons);

-- Give every existing shop a slug derived from its name.
update public.salons
   set slug = regexp_replace(lower(trim(name)), '[^a-z0-9]+', '-', 'g')
 where slug is null;
update public.salons set slug = trim(both '-' from slug) where slug like '-%' or slug like '%-';
update public.salons set slug = 'shop-' || id where coalesce(slug, '') = '';
update public.salons set kind = 'barber' where kind is null;

create unique index if not exists salons_slug_key on public.salons (lower(slug));

do $$
begin
  alter table public.salons alter column slug set not null;
exception when others then null;
end $$;


-- ============================================================
-- 1b. Categories  — the top level of the directory
--
--   ICON
--   |- barbers      -> shop, shop, shop
--   |- nail-salon   -> shop, shop, shop
--   `- car-wash     -> shop, shop, shop
--
-- A shop still has its own direct link (?shop=<slug>) for its QR code;
-- the category is only how people browse when they arrive without one.
-- ============================================================

create table if not exists public.categories (
  slug       text primary key,
  name       text not null,
  tagline    text,
  sort_order int not null default 0,
  is_active  boolean not null default true
);

insert into public.categories (slug, name, tagline, sort_order) values
  ('barbers',    'Barbers',     'Cuts, beards and a hot towel',      1),
  ('nail-salon', 'Nail salons', 'Manicures, pedicures and gel',      2),
  ('car-wash',   'Car wash',    'Wash, polish and interior cleaning', 3)
on conflict (slug) do update
  set name = excluded.name,
      tagline = excluded.tagline,
      sort_order = excluded.sort_order;

alter table public.salons add column if not exists category text;

do $$
begin
  alter table public.salons
    add constraint salons_category_fk foreign key (category)
    references public.categories(slug) on update cascade;
exception when duplicate_object then null;
end $$;

-- Put every existing shop in a category, inferred from its kind.
update public.salons
   set category = case
     when kind = 'nails'   then 'nail-salon'
     when kind = 'carwash' then 'car-wash'
     else 'barbers'
   end
 where category is null;

create index if not exists salons_category_idx
  on public.salons (category, name);


-- ============================================================
-- 2. Opening hours + closures  ("owner adds open slots")
-- ============================================================

create table if not exists public.salon_hours (
  salon_id   bigint not null references public.salons(id) on delete cascade,
  weekday    int    not null check (weekday between 0 and 6),   -- 0 = Sunday
  is_open    boolean not null default true,
  opens_at   time   not null default '09:00',
  closes_at  time   not null default '19:00',
  primary key (salon_id, weekday)
);

-- Default week for any shop that has none yet: open Mon-Sat, closed Sunday.
insert into public.salon_hours (salon_id, weekday, is_open, opens_at, closes_at)
select s.id, d.wd, d.wd <> 0, '09:00'::time, '19:00'::time
  from public.salons s
 cross join (select generate_series(0, 6) as wd) d
 where not exists (
   select 1 from public.salon_hours h where h.salon_id = s.id and h.weekday = d.wd
 );

create table if not exists public.salon_closures (
  id       bigint generated always as identity primary key,
  salon_id bigint not null references public.salons(id) on delete cascade,
  on_date  date not null,
  reason   text,
  unique (salon_id, on_date)
);


-- ============================================================
-- 3. staff  — barbers / beauticians
-- ============================================================

create table if not exists public.staff (
  id         bigint generated always as identity primary key,
  salon_id   bigint not null references public.salons(id) on delete cascade,
  name       text not null check (char_length(trim(name)) between 1 and 60),
  title      text,
  is_active  boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists staff_salon_idx on public.staff (salon_id, is_active, sort_order);


-- ============================================================
-- 4. services  — with audience and price
-- ============================================================

create table if not exists public.services (
  id               bigint generated always as identity primary key,
  salon_id         bigint not null references public.salons(id) on delete cascade,
  name             text not null check (char_length(trim(name)) between 1 and 60),
  audience         text not null default 'unisex'
                   check (audience in ('men', 'women', 'kids', 'unisex')),
  category         text not null default 'hair'
                   check (category in ('hair', 'beard', 'nails', 'skin', 'spa', 'other')),
  duration_minutes int  not null default 30 check (duration_minutes between 5 and 480),
  price_minor      int  not null default 0 check (price_minor >= 0),  -- paise / cents
  is_active        boolean not null default true,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now()
);

create index if not exists services_salon_idx
  on public.services (salon_id, is_active, audience, sort_order);

-- Which staff can perform which service. No rows for a service means
-- "anyone can do it", which keeps setup simple for small shops.
create table if not exists public.staff_services (
  staff_id   bigint not null references public.staff(id) on delete cascade,
  service_id bigint not null references public.services(id) on delete cascade,
  primary key (staff_id, service_id)
);

-- Starter menu for any shop with no services yet.
insert into public.services (salon_id, name, audience, category, duration_minutes, price_minor, sort_order)
select s.id, m.name, m.audience, m.category, m.mins, m.price, m.ord
  from public.salons s
 cross join (values
    ('Haircut',            'men',    'hair',  30,  25000, 1),
    ('Haircut & beard',     'men',    'hair',  45,  40000, 2),
    ('Beard trim',          'men',    'beard', 15,  12000, 3),
    ('Kids haircut',        'kids',   'hair',  20,  18000, 4),
    ('Haircut & styling',   'women',  'hair',  60,  60000, 5),
    ('Manicure',            'women',  'nails', 45,  50000, 6),
    ('Pedicure',            'women',  'nails', 60,  70000, 7),
    ('Gel nails',           'women',  'nails', 75,  95000, 8)
 ) as m(name, audience, category, mins, price, ord)
 where not exists (select 1 from public.services v where v.salon_id = s.id);

-- One starter chair so availability is never zero on a fresh shop.
insert into public.staff (salon_id, name, title, sort_order)
select s.id, 'Chair 1', 'Stylist', 1
  from public.salons s
 where not exists (select 1 from public.staff t where t.salon_id = s.id);


-- ============================================================
-- 5. waitlists  — the live queue (v1/v2 table, extended)
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

alter table public.waitlists add column if not exists ticket_no      int;
alter table public.waitlists add column if not exists service_date   date;
alter table public.waitlists add column if not exists preferred_time timestamptz;
alter table public.waitlists add column if not exists service_id     bigint references public.services(id) on delete set null;
alter table public.waitlists add column if not exists staff_id       bigint references public.staff(id) on delete set null;
alter table public.waitlists add column if not exists audience       text;

do $$
begin
  alter table public.waitlists add constraint waitlists_audience_chk
    check (audience is null or audience in ('men', 'women', 'kids', 'unisex'));
exception when duplicate_object then null;
end $$;

update public.waitlists set service_date = (join_time at time zone 'UTC')::date
 where service_date is null;

alter table public.waitlists alter column service_date set default current_date;

do $$
begin
  alter table public.waitlists alter column service_date set not null;
exception when others then null;
end $$;

with numbered as (
  select id, row_number() over (partition by salon_id, service_date
                                order by join_time, id) as n
    from public.waitlists where ticket_no is null
)
update public.waitlists w set ticket_no = numbered.n
  from numbered where w.id = numbered.id;

create unique index if not exists waitlists_ticket_key
  on public.waitlists (salon_id, service_date, ticket_no);
create index if not exists waitlists_queue_idx
  on public.waitlists (salon_id, status, join_time);


-- ============================================================
-- 6. appointments  — future bookings
-- ============================================================

create table if not exists public.appointments (
  id            bigint generated always as identity primary key,
  salon_id      bigint not null references public.salons(id) on delete cascade,
  service_id    bigint references public.services(id) on delete set null,
  staff_id      bigint references public.staff(id) on delete set null,
  customer_name text not null check (char_length(trim(customer_name)) between 2 and 80),
  notes         text check (char_length(notes) <= 500),
  audience      text check (audience is null or audience in ('men','women','kids','unisex')),
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  on_date       date not null,
  status        text not null default 'booked'
                check (status in ('booked', 'arrived', 'in_chair', 'done', 'cancelled', 'no_show')),
  -- Lets a customer re-open their own booking without any login.
  lookup_code   text not null default encode(gen_random_bytes(8), 'hex'),
  source        text not null default 'online',
  created_at    timestamptz not null default now(),
  check (ends_at > starts_at)
);

create index if not exists appointments_day_idx
  on public.appointments (salon_id, on_date, starts_at);
create index if not exists appointments_staff_idx
  on public.appointments (staff_id, starts_at)
  where status in ('booked', 'arrived', 'in_chair');
create unique index if not exists appointments_lookup_key
  on public.appointments (lookup_code);


-- ============================================================
-- 7. contacts  — phone numbers, now OPTIONAL
--    Kept off the public tables: Realtime filters rows by RLS but not
--    columns, so anything on `waitlists` is readable by every visitor.
-- ============================================================

create table if not exists public.waitlist_contacts (
  entry_id     bigint primary key references public.waitlists(id) on delete cascade,
  phone_number text not null check (phone_number ~ '^\+?[0-9]{10,15}$'),
  created_at   timestamptz not null default now()
);

create table if not exists public.appointment_contacts (
  appointment_id bigint primary key references public.appointments(id) on delete cascade,
  phone_number   text not null check (phone_number ~ '^\+?[0-9]{10,15}$'),
  created_at     timestamptz not null default now()
);

-- v1 -> v2/v3: move any phone column off waitlists.
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'waitlists'
       and column_name = 'phone_number'
  ) then
    insert into public.waitlist_contacts (entry_id, phone_number)
    select id, phone_number from public.waitlists
     where phone_number is not null and phone_number ~ '^\+?[0-9]{10,15}$'
    on conflict (entry_id) do nothing;

    alter table public.waitlists drop column phone_number;
    raise notice 'Moved phone numbers into waitlist_contacts';
  end if;
end $$;


-- ============================================================
-- 8. admins + sessions
-- ============================================================

create table if not exists public.admins (
  id              bigint generated always as identity primary key,
  admin_id        text not null,
  password_hash   text not null,
  display_name    text not null,
  salon_id        bigint references public.salons(id) on delete cascade,
  role            text not null default 'stylist'
                  check (role in ('stylist', 'manager', 'owner')),
  is_active       boolean not null default true,
  failed_attempts int not null default 0,
  locked_until    timestamptz,
  last_login_at   timestamptz,
  created_at      timestamptz not null default now()
);

create unique index if not exists admins_admin_id_key on public.admins (lower(admin_id));

create table if not exists public.admin_sessions (
  token        uuid primary key default gen_random_uuid(),
  admin_pk     bigint not null references public.admins(id) on delete cascade,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '12 hours'
);

create index if not exists admin_sessions_admin_idx on public.admin_sessions (admin_pk);


-- ============================================================
-- 9. Row Level Security
--
-- Browsers may read: salons, services, staff, salon_hours (the shop
-- menu) and today's open queue. They may NOT read appointments —
-- those are other people's names and times — so availability comes
-- from available_slots() instead, which returns only free times.
-- ============================================================

alter table public.categories           enable row level security;
alter table public.salons               enable row level security;
alter table public.salon_hours          enable row level security;
alter table public.salon_closures       enable row level security;
alter table public.staff                enable row level security;
alter table public.services             enable row level security;
alter table public.staff_services       enable row level security;
alter table public.waitlists            enable row level security;
alter table public.appointments         enable row level security;
alter table public.waitlist_contacts    enable row level security;
alter table public.appointment_contacts enable row level security;
alter table public.admins               enable row level security;
alter table public.admin_sessions       enable row level security;

drop policy if exists "dev open read"     on public.waitlists;
drop policy if exists "dev open insert"   on public.waitlists;
drop policy if exists "dev open update"   on public.waitlists;
drop policy if exists "queue public read" on public.waitlists;
drop policy if exists "public check in"   on public.waitlists;
drop policy if exists "salons readable"   on public.salons;

create policy "salons readable" on public.salons
  for select to anon, authenticated using (true);

drop policy if exists "categories readable" on public.categories;
create policy "categories readable" on public.categories
  for select to anon, authenticated using (is_active);

drop policy if exists "hours readable" on public.salon_hours;
create policy "hours readable" on public.salon_hours
  for select to anon, authenticated using (true);

drop policy if exists "closures readable" on public.salon_closures;
create policy "closures readable" on public.salon_closures
  for select to anon, authenticated using (true);

drop policy if exists "staff readable" on public.staff;
create policy "staff readable" on public.staff
  for select to anon, authenticated using (is_active);

drop policy if exists "services readable" on public.services;
create policy "services readable" on public.services
  for select to anon, authenticated using (is_active);

drop policy if exists "staff services readable" on public.staff_services;
create policy "staff services readable" on public.staff_services
  for select to anon, authenticated using (true);

create policy "queue public read" on public.waitlists
  for select to anon, authenticated
  using (service_date = current_date and status in ('waiting', 'in_chair'));

-- appointments, both contacts tables, admins and admin_sessions get NO
-- policy at all: with RLS on and no policy, every direct browser query
-- returns nothing.


-- ============================================================
-- 10. Functions
-- ============================================================

-- ---------- 10a. session plumbing ----------

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
   where s.token = p_token and s.expires_at > now() and a.is_active;

  if not found then
    raise exception 'Session expired. Sign in again.' using errcode = '28000';
  end if;

  return v_admin;
end $$;


-- Guards every owner write: the shop they are signed in to, or bust.
create or replace function public._admin_salon(p_token uuid)
returns bigint
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);
  if v_admin.salon_id is null then
    raise exception 'This account is not attached to a shop' using errcode = '42501';
  end if;
  return v_admin.salon_id;
end $$;


create or replace function public._require_manager(p_token uuid)
returns bigint
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);
  if v_admin.role not in ('manager', 'owner') then
    raise exception 'Only a manager or owner can change shop settings' using errcode = '42501';
  end if;
  if v_admin.salon_id is null then
    raise exception 'This account is not attached to a shop' using errcode = '42501';
  end if;
  return v_admin.salon_id;
end $$;


-- ---------- 10b. sign in ----------
-- Returns failures as { ok:false } instead of raising: RAISE would abort
-- the transaction and roll back the failed_attempts increment, so the
-- lockout counter could never accumulate. Callers must check `ok`.

create or replace function public.admin_login(p_admin_id text, p_password text)
returns json
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  v_admin public.admins;
  v_token uuid;
  v_wait  int;
  v_slug  text;
  c_denied constant text := 'Incorrect staff ID or password';
begin
  if coalesce(trim(p_admin_id), '') = '' or coalesce(p_password, '') = '' then
    return json_build_object('ok', false, 'error', 'Enter your staff ID and password');
  end if;

  select * into v_admin from public.admins
   where lower(admin_id) = lower(trim(p_admin_id));

  if not found or not v_admin.is_active then
    perform pg_sleep(0.4);
    return json_build_object('ok', false, 'error', c_denied);
  end if;

  if v_admin.locked_until is not null and v_admin.locked_until > now() then
    v_wait := greatest(1, ceil(extract(epoch from (v_admin.locked_until - now())) / 60));
    return json_build_object('ok', false, 'locked', true,
      'error', 'Too many attempts. Try again in ' || v_wait || ' minute' ||
               case when v_wait = 1 then '' else 's' end || '.');
  end if;

  if v_admin.password_hash <> crypt(p_password, v_admin.password_hash) then
    update public.admins
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5
                               then now() + interval '15 minutes'
                               else locked_until end
     where id = v_admin.id
    returning failed_attempts, locked_until
      into v_admin.failed_attempts, v_admin.locked_until;

    perform pg_sleep(0.4);

    if v_admin.locked_until is not null and v_admin.locked_until > now() then
      return json_build_object('ok', false, 'locked', true,
        'error', 'Too many attempts. Locked for 15 minutes.');
    end if;
    return json_build_object('ok', false, 'error', c_denied,
      'attempts_left', greatest(0, 5 - v_admin.failed_attempts));
  end if;

  update public.admins
     set failed_attempts = 0, locked_until = null, last_login_at = now()
   where id = v_admin.id;

  delete from public.admin_sessions where admin_pk = v_admin.id or expires_at < now();
  insert into public.admin_sessions (admin_pk) values (v_admin.id) returning token into v_token;

  select slug into v_slug from public.salons where id = v_admin.salon_id;

  return json_build_object(
    'ok', true, 'token', v_token,
    'admin_id', v_admin.admin_id, 'display_name', v_admin.display_name,
    'role', v_admin.role, 'salon_id', v_admin.salon_id, 'salon_slug', v_slug,
    'expires_at', now() + interval '12 hours');
end $$;


create or replace function public.admin_session(p_token uuid)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_admin public.admins; v_salon public.salons;
begin
  v_admin := public._admin_from_token(p_token);
  update public.admin_sessions set last_seen_at = now() where token = p_token;
  select * into v_salon from public.salons where id = v_admin.salon_id;

  return json_build_object(
    'admin_id', v_admin.admin_id, 'display_name', v_admin.display_name,
    'role', v_admin.role, 'salon_id', v_admin.salon_id,
    'salon_slug', v_salon.slug, 'salon_name', v_salon.name);
end $$;


create or replace function public.admin_logout(p_token uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from public.admin_sessions where token = p_token;
$$;


create or replace function public.admin_change_password(
  p_token uuid, p_current text, p_new text)
returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_admin public.admins;
begin
  v_admin := public._admin_from_token(p_token);
  if v_admin.password_hash <> crypt(p_current, v_admin.password_hash) then
    raise exception 'Current password is incorrect' using errcode = '28P01';
  end if;
  if char_length(p_new) < 8 then
    raise exception 'New password must be at least 8 characters' using errcode = '22023';
  end if;
  update public.admins set password_hash = crypt(p_new, gen_salt('bf', 12))
   where id = v_admin.id;
  delete from public.admin_sessions where admin_pk = v_admin.id;
end $$;


-- ---------- 10c. public shop lookup ----------

create or replace function public.shop_by_slug(p_slug text)
returns json
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v json;
begin
  select json_build_object(
    'id', s.id, 'slug', s.slug, 'name', s.name, 'kind', s.kind,
    'category', s.category,
    'address', s.address, 'is_open', s.is_open,
    'phone_required', s.phone_required, 'currency', s.currency,
    'slot_minutes', s.slot_minutes, 'lead_minutes', s.lead_minutes,
    'horizon_days', s.horizon_days,
    'active_chairs', s.active_chairs, 'avg_service_minutes', s.avg_service_minutes,
    'contact_phone', s.contact_phone,
    'hours', (
      select coalesce(json_agg(json_build_object(
                'weekday', h.weekday, 'is_open', h.is_open,
                'opens_at', to_char(h.opens_at, 'HH24:MI'),
                'closes_at', to_char(h.closes_at, 'HH24:MI'))
              order by h.weekday), '[]'::json)
        from public.salon_hours h where h.salon_id = s.id),
    'services', (
      select coalesce(json_agg(json_build_object(
                'id', v.id, 'name', v.name, 'audience', v.audience,
                'category', v.category, 'duration_minutes', v.duration_minutes,
                'price_minor', v.price_minor) order by v.sort_order, v.id), '[]'::json)
        from public.services v where v.salon_id = s.id and v.is_active),
    'staff', (
      select coalesce(json_agg(json_build_object(
                'id', t.id, 'name', t.name, 'title', t.title)
              order by t.sort_order, t.id), '[]'::json)
        from public.staff t where t.salon_id = s.id and t.is_active)
  ) into v
  from public.salons s
  where lower(s.slug) = lower(trim(coalesce(p_slug, '')))
     or (p_slug ~ '^[0-9]+$' and s.id = p_slug::bigint);

  if v is null then
    raise exception 'No shop found for "%"', p_slug using errcode = '02000';
  end if;
  return v;
end $$;


create or replace function public.shop_list()
returns table (id bigint, slug text, name text, kind text, address text, is_open boolean)
language sql security definer stable set search_path = public, pg_temp as $$
  select id, slug, name, kind, address, is_open from public.salons order by name;
$$;


-- ---------- 10d. availability ----------
-- Returns only FREE start times, so no customer ever learns who else is
-- booked. Capacity at a given moment = number of active staff who could
-- take the service.

create or replace function public.available_slots(
  p_salon      bigint,
  p_date       date,
  p_service_id bigint default null,
  p_staff_id   bigint default null)
returns table (starts_at timestamptz, seats_left int)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare
  v_salon    public.salons;
  v_dur      int;
  v_open     time;
  v_close    time;
  v_is_open  boolean;
  v_capacity int;
  v_earliest timestamptz;
begin
  select * into v_salon from public.salons where id = p_salon;
  if not found or not v_salon.is_open then return; end if;

  if p_date < current_date
     or p_date > current_date + make_interval(days => v_salon.horizon_days) then
    return;
  end if;

  if exists (select 1 from public.salon_closures c
              where c.salon_id = p_salon and c.on_date = p_date) then
    return;
  end if;

  select h.is_open, h.opens_at, h.closes_at
    into v_is_open, v_open, v_close
    from public.salon_hours h
   where h.salon_id = p_salon
     and h.weekday = extract(dow from p_date)::int;

  if not coalesce(v_is_open, false) then return; end if;

  select coalesce(
    (select duration_minutes from public.services
      where id = p_service_id and salon_id = p_salon and is_active),
    v_salon.avg_service_minutes, 30)
  into v_dur;

  -- How many people could work this slot.
  if p_staff_id is not null then
    v_capacity := 1;
  else
    select count(*) into v_capacity
      from public.staff t
     where t.salon_id = p_salon and t.is_active
       and (p_service_id is null
            or not exists (select 1 from public.staff_services ss
                            where ss.service_id = p_service_id)
            or exists (select 1 from public.staff_services ss
                        where ss.service_id = p_service_id and ss.staff_id = t.id));
  end if;

  if coalesce(v_capacity, 0) = 0 then
    v_capacity := greatest(1, v_salon.active_chairs);
  end if;

  v_earliest := now() + make_interval(mins => v_salon.lead_minutes);

  return query
  with grid as (
    select gs as slot_start
      from generate_series(
        (p_date + v_open)::timestamptz,
        (p_date + v_close)::timestamptz - make_interval(mins => v_dur),
        make_interval(mins => greatest(5, v_salon.slot_minutes))
      ) gs
  ),
  busy as (
    select a.starts_at, a.ends_at, a.staff_id
      from public.appointments a
     where a.salon_id = p_salon
       and a.on_date = p_date
       and a.status in ('booked', 'arrived', 'in_chair')
       and (p_staff_id is null or a.staff_id = p_staff_id or a.staff_id is null)
  )
  select g.slot_start,
         (v_capacity - (
            select count(*) from busy b
             where b.starts_at < g.slot_start + make_interval(mins => v_dur)
               and b.ends_at   > g.slot_start
         ))::int as seats
    from grid g
   where g.slot_start >= v_earliest
     and (v_capacity - (
            select count(*) from busy b
             where b.starts_at < g.slot_start + make_interval(mins => v_dur)
               and b.ends_at   > g.slot_start
         )) > 0
   order by g.slot_start;
end $$;


-- Day-by-day count of free slots, for the customer calendar.
create or replace function public.availability_calendar(
  p_salon bigint, p_from date, p_days int default 14, p_service_id bigint default null)
returns table (on_date date, free_slots int)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_days int;
begin
  v_days := least(greatest(coalesce(p_days, 14), 1), 60);
  return query
    select d::date,
           (select count(*)::int from public.available_slots(p_salon, d::date, p_service_id))
      from generate_series(p_from, p_from + (v_days - 1), interval '1 day') d
     order by d;
end $$;


-- ---------- 10e. public booking + check-in ----------

create or replace function public.book_appointment(
  p_salon      bigint,
  p_service_id bigint,
  p_starts_at  timestamptz,
  p_name       text,
  p_phone      text default null,
  p_notes      text default null,
  p_staff_id   bigint default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_salon public.salons;
  v_svc   public.services;
  v_phone text;
  v_end   timestamptz;
  v_id    bigint;
  v_code  text;
  v_free  int;
  v_day   date;
begin
  select * into v_salon from public.salons where id = p_salon;
  if not found or not v_salon.is_open then
    raise exception 'This shop is not taking bookings right now' using errcode = '22023';
  end if;

  if char_length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Enter your name' using errcode = '22023';
  end if;

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if v_salon.phone_required and v_phone is null then
    raise exception 'A mobile number is required at this shop' using errcode = '22023';
  end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{10,15}$' then
    raise exception 'Enter a valid mobile number, or leave it blank' using errcode = '22023';
  end if;

  select * into v_svc from public.services
   where id = p_service_id and salon_id = p_salon and is_active;
  if not found then
    raise exception 'That service is not available' using errcode = '22023';
  end if;

  v_end := p_starts_at + make_interval(mins => v_svc.duration_minutes);

  -- Serialise booking per shop so two people cannot take the last seat.
  perform pg_advisory_xact_lock(p_salon);

  select count(*) into v_free
    from public.available_slots(p_salon, (p_starts_at at time zone 'UTC')::date,
                                p_service_id, p_staff_id) s
   where s.starts_at = p_starts_at;

  if v_free = 0 then
    -- Re-check against the local date too, in case of a timezone edge.
    select count(*) into v_free
      from public.available_slots(p_salon, p_starts_at::date, p_service_id, p_staff_id) s
     where s.starts_at = p_starts_at;
  end if;

  if v_free = 0 then
    -- "Taken" is only one of several reasons a slot is not on offer, and
    -- the wrong reason sends people hunting for a different time when the
    -- real problem is the date or the day. Work out which it is.
    v_day := (p_starts_at at time zone 'UTC')::date;

    if p_starts_at < now() then
      raise exception 'That time has already passed' using errcode = '22023';
    end if;

    if v_day > (current_date + make_interval(days => v_salon.horizon_days)) then
      raise exception 'This shop only takes bookings up to % days ahead',
        v_salon.horizon_days using errcode = '22023';
    end if;

    if exists (select 1 from public.salon_closures c
                where c.salon_id = p_salon and c.on_date = v_day) then
      raise exception 'The shop is closed that day' using errcode = '22023';
    end if;

    if not exists (select 1 from public.salon_hours h
                    where h.salon_id = p_salon
                      and h.weekday = extract(dow from v_day)::int
                      and h.is_open) then
      raise exception 'The shop is closed on that day of the week' using errcode = '22023';
    end if;

    if not exists (select 1 from public.staff t
                    where t.salon_id = p_salon and t.is_active) then
      raise exception 'This shop has nobody available to book yet' using errcode = '22023';
    end if;

    raise exception 'That time has just been taken. Pick another slot.' using errcode = '23505';
  end if;

  insert into public.appointments
    (salon_id, service_id, staff_id, customer_name, notes, audience,
     starts_at, ends_at, on_date, source)
  values
    (p_salon, p_service_id, p_staff_id, trim(p_name),
     nullif(trim(coalesce(p_notes, '')), ''), v_svc.audience,
     p_starts_at, v_end, p_starts_at::date, 'online')
  returning id, lookup_code into v_id, v_code;

  if v_phone is not null then
    insert into public.appointment_contacts (appointment_id, phone_number)
    values (v_id, v_phone);
  end if;

  return json_build_object(
    'id', v_id, 'lookup_code', v_code,
    'starts_at', p_starts_at, 'ends_at', v_end,
    'service', v_svc.name, 'duration_minutes', v_svc.duration_minutes,
    'price_minor', v_svc.price_minor);
end $$;


-- A customer re-opening their own booking: needs the code, gets only
-- their own row.
create or replace function public.appointment_status(p_code text)
returns json
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v json;
begin
  select json_build_object(
    'id', a.id, 'status', a.status, 'starts_at', a.starts_at, 'ends_at', a.ends_at,
    'customer_name', a.customer_name, 'notes', a.notes,
    'service', v2.name, 'price_minor', v2.price_minor,
    'staff', t.name, 'shop', s.name, 'shop_slug', s.slug, 'currency', s.currency)
    into v
    from public.appointments a
    join public.salons s on s.id = a.salon_id
    left join public.services v2 on v2.id = a.service_id
    left join public.staff t on t.id = a.staff_id
   where a.lookup_code = p_code;

  if v is null then
    raise exception 'Booking not found' using errcode = '02000';
  end if;
  return v;
end $$;


create or replace function public.cancel_appointment(p_code text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.appointments
     set status = 'cancelled'
   where lookup_code = p_code and status in ('booked', 'arrived');
  if not found then
    raise exception 'That booking can no longer be cancelled here' using errcode = '02000';
  end if;
end $$;


create or replace function public.check_in(
  p_salon          bigint,
  p_name           text,
  p_phone          text default null,
  p_notes          text default null,
  p_preferred_time timestamptz default null,
  p_service_id     bigint default null,
  p_staff_id       bigint default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_salon  public.salons;
  v_phone  text;
  v_ticket int;
  v_id     bigint;
  v_aud    text;
begin
  select * into v_salon from public.salons where id = p_salon;
  if not found or not v_salon.is_open then
    raise exception 'This shop is not taking check-ins right now' using errcode = '22023';
  end if;

  if char_length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Enter your name' using errcode = '22023';
  end if;

  v_phone := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
  if v_salon.phone_required and v_phone is null then
    raise exception 'A mobile number is required at this shop' using errcode = '22023';
  end if;
  if v_phone is not null and v_phone !~ '^\+?[0-9]{10,15}$' then
    raise exception 'Enter a valid mobile number, or leave it blank' using errcode = '22023';
  end if;

  -- Only de-duplicate when we actually have a number to compare.
  if v_phone is not null and exists (
    select 1 from public.waitlists w
      join public.waitlist_contacts c on c.entry_id = w.id
     where w.salon_id = p_salon and w.service_date = current_date
       and w.status in ('waiting', 'in_chair') and c.phone_number = v_phone
  ) then
    raise exception 'That number already has a ticket today' using errcode = '23505';
  end if;

  select audience into v_aud from public.services
   where id = p_service_id and salon_id = p_salon;

  perform pg_advisory_xact_lock(p_salon);

  select coalesce(max(ticket_no), 0) + 1 into v_ticket
    from public.waitlists where salon_id = p_salon and service_date = current_date;

  insert into public.waitlists
    (salon_id, customer_name, clip_notes, status, ticket_no, service_date,
     preferred_time, service_id, staff_id, audience)
  values
    (p_salon, trim(p_name), nullif(trim(coalesce(p_notes, '')), ''), 'waiting',
     v_ticket, current_date, p_preferred_time, p_service_id, p_staff_id, v_aud)
  returning id into v_id;

  if v_phone is not null then
    insert into public.waitlist_contacts (entry_id, phone_number) values (v_id, v_phone);
  end if;

  return json_build_object('entry_id', v_id, 'ticket_no', v_ticket);
end $$;


-- ---------- 10f. staff: the line ----------

create or replace function public.admin_queue(p_token uuid)
returns table (
  id bigint, ticket_no int, customer_name text, phone_number text,
  clip_notes text, status text, join_time timestamptz,
  preferred_time timestamptz, called_at timestamptz,
  service_name text, staff_name text, audience text)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return query
    select w.id, w.ticket_no, w.customer_name, c.phone_number,
           w.clip_notes, w.status, w.join_time, w.preferred_time, w.called_at,
           v2.name, t.name, w.audience
      from public.waitlists w
      left join public.waitlist_contacts c on c.entry_id = w.id
      left join public.services v2 on v2.id = w.service_id
      left join public.staff t on t.id = w.staff_id
     where w.salon_id = v_salon
       and w.service_date = current_date
       and w.status in ('waiting', 'in_chair')
     order by w.join_time;
end $$;


create or replace function public.admin_register_walkin(
  p_token uuid, p_name text, p_phone text default null,
  p_notes text default null, p_preferred_time timestamptz default null,
  p_service_id bigint default null, p_staff_id bigint default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return public.check_in(v_salon, p_name, p_phone, p_notes, p_preferred_time,
                         p_service_id, p_staff_id);
end $$;


create or replace function public.admin_set_status(
  p_token uuid, p_entry_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  if p_status not in ('waiting', 'in_chair', 'done', 'cancelled') then
    raise exception 'Unknown status: %', p_status using errcode = '22023';
  end if;

  update public.waitlists
     set status = p_status,
         called_at = case when p_status = 'in_chair' then now() else called_at end,
         finished_at = case when p_status in ('done', 'cancelled') then now() end
   where id = p_entry_id and salon_id = v_salon and service_date = current_date;

  if not found then
    raise exception 'That ticket is no longer in today''s queue' using errcode = '02000';
  end if;
end $$;


create or replace function public.admin_purge(p_token uuid)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint; v_count int;
begin
  v_salon := public._require_manager(p_token);
  with cleared as (
    update public.waitlists set status = 'cancelled', finished_at = now()
     where salon_id = v_salon and service_date = current_date
       and status in ('waiting', 'in_chair')
    returning 1)
  select count(*) into v_count from cleared;
  return v_count;
end $$;


-- ---------- 10g. staff: the calendar ----------

create or replace function public.admin_appointments(
  p_token uuid, p_from date default null, p_to date default null)
returns table (
  id bigint, starts_at timestamptz, ends_at timestamptz, on_date date,
  customer_name text, phone_number text, notes text, status text,
  service_name text, staff_name text, staff_id bigint,
  price_minor int, audience text, lookup_code text)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint; v_from date; v_to date;
begin
  v_salon := public._admin_salon(p_token);
  v_from := coalesce(p_from, current_date);
  v_to   := coalesce(p_to, v_from);
  if v_to < v_from then v_to := v_from; end if;
  if v_to > v_from + 92 then v_to := v_from + 92; end if;

  return query
    select a.id, a.starts_at, a.ends_at, a.on_date,
           a.customer_name, c.phone_number, a.notes, a.status,
           v2.name, t.name, a.staff_id, v2.price_minor, a.audience, a.lookup_code
      from public.appointments a
      left join public.appointment_contacts c on c.appointment_id = a.id
      left join public.services v2 on v2.id = a.service_id
      left join public.staff t on t.id = a.staff_id
     where a.salon_id = v_salon
       and a.on_date between v_from and v_to
     order by a.starts_at, a.id;
end $$;


create or replace function public.admin_appointment_counts(
  p_token uuid, p_from date, p_days int default 35)
returns table (on_date date, booked int, cancelled int)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint; v_days int;
begin
  v_salon := public._admin_salon(p_token);
  v_days := least(greatest(coalesce(p_days, 35), 1), 92);
  return query
    select d::date,
           count(*) filter (where a.status in ('booked','arrived','in_chair','done'))::int,
           count(*) filter (where a.status in ('cancelled','no_show'))::int
      from generate_series(p_from, p_from + (v_days - 1), interval '1 day') d
      left join public.appointments a
             on a.salon_id = v_salon and a.on_date = d::date
     group by d
     order by d;
end $$;


create or replace function public.admin_set_appointment_status(
  p_token uuid, p_id bigint, p_status text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  if p_status not in ('booked','arrived','in_chair','done','cancelled','no_show') then
    raise exception 'Unknown status: %', p_status using errcode = '22023';
  end if;
  update public.appointments set status = p_status
   where id = p_id and salon_id = v_salon;
  if not found then
    raise exception 'Booking not found' using errcode = '02000';
  end if;
end $$;


create or replace function public.admin_book(
  p_token uuid, p_service_id bigint, p_starts_at timestamptz,
  p_name text, p_phone text default null, p_notes text default null,
  p_staff_id bigint default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return public.book_appointment(v_salon, p_service_id, p_starts_at,
                                 p_name, p_phone, p_notes, p_staff_id);
end $$;


-- ---------- 10h. owner: services ----------

create or replace function public.admin_services(p_token uuid)
returns table (
  id bigint, name text, audience text, category text,
  duration_minutes int, price_minor int, is_active boolean, sort_order int)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return query
    select v.id, v.name, v.audience, v.category, v.duration_minutes,
           v.price_minor, v.is_active, v.sort_order
      from public.services v where v.salon_id = v_salon
     order by v.sort_order, v.id;
end $$;


create or replace function public.admin_service_save(
  p_token uuid, p_id bigint, p_name text, p_audience text, p_category text,
  p_duration int, p_price_minor int, p_is_active boolean default true,
  p_sort int default 0)
returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint; v_id bigint;
begin
  v_salon := public._require_manager(p_token);

  if char_length(trim(coalesce(p_name, ''))) < 1 then
    raise exception 'Give the service a name' using errcode = '22023';
  end if;
  if p_audience not in ('men','women','kids','unisex') then
    raise exception 'Audience must be men, women, kids or unisex' using errcode = '22023';
  end if;
  if p_category not in ('hair','beard','nails','skin','spa','other') then
    raise exception 'Unknown category: %', p_category using errcode = '22023';
  end if;
  if p_duration < 5 or p_duration > 480 then
    raise exception 'Duration must be between 5 and 480 minutes' using errcode = '22023';
  end if;
  if p_price_minor < 0 then
    raise exception 'Price cannot be negative' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.services
      (salon_id, name, audience, category, duration_minutes, price_minor, is_active, sort_order)
    values
      (v_salon, trim(p_name), p_audience, p_category, p_duration, p_price_minor,
       coalesce(p_is_active, true), coalesce(p_sort, 0))
    returning id into v_id;
  else
    update public.services
       set name = trim(p_name), audience = p_audience, category = p_category,
           duration_minutes = p_duration, price_minor = p_price_minor,
           is_active = coalesce(p_is_active, true), sort_order = coalesce(p_sort, 0)
     where id = p_id and salon_id = v_salon
    returning id into v_id;
    if v_id is null then
      raise exception 'Service not found' using errcode = '02000';
    end if;
  end if;
  return v_id;
end $$;


-- Soft delete, so past bookings keep their service name.
create or replace function public.admin_service_retire(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._require_manager(p_token);
  update public.services set is_active = false
   where id = p_id and salon_id = v_salon;
  if not found then
    raise exception 'Service not found' using errcode = '02000';
  end if;
end $$;


-- ---------- 10i. owner: staff ----------

create or replace function public.admin_staff(p_token uuid)
returns table (id bigint, name text, title text, is_active boolean, sort_order int)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return query
    select t.id, t.name, t.title, t.is_active, t.sort_order
      from public.staff t where t.salon_id = v_salon
     order by t.sort_order, t.id;
end $$;


create or replace function public.admin_staff_save(
  p_token uuid, p_id bigint, p_name text, p_title text default null,
  p_is_active boolean default true, p_sort int default 0)
returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint; v_id bigint;
begin
  v_salon := public._require_manager(p_token);
  if char_length(trim(coalesce(p_name, ''))) < 1 then
    raise exception 'Give the person a name' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.staff (salon_id, name, title, is_active, sort_order)
    values (v_salon, trim(p_name), nullif(trim(coalesce(p_title,'')), ''),
            coalesce(p_is_active, true), coalesce(p_sort, 0))
    returning id into v_id;
  else
    update public.staff
       set name = trim(p_name), title = nullif(trim(coalesce(p_title,'')), ''),
           is_active = coalesce(p_is_active, true), sort_order = coalesce(p_sort, 0)
     where id = p_id and salon_id = v_salon
    returning id into v_id;
    if v_id is null then
      raise exception 'Person not found' using errcode = '02000';
    end if;
  end if;
  return v_id;
end $$;


create or replace function public.admin_staff_retire(p_token uuid, p_id bigint)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._require_manager(p_token);
  update public.staff set is_active = false where id = p_id and salon_id = v_salon;
  if not found then
    raise exception 'Person not found' using errcode = '02000';
  end if;
end $$;


-- ---------- 10j. owner: hours, closures, shop settings ----------

create or replace function public.admin_hours(p_token uuid)
returns table (weekday int, is_open boolean, opens_at text, closes_at text)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return query
    select h.weekday, h.is_open,
           to_char(h.opens_at, 'HH24:MI'), to_char(h.closes_at, 'HH24:MI')
      from public.salon_hours h where h.salon_id = v_salon
     order by h.weekday;
end $$;


create or replace function public.admin_hours_save(
  p_token uuid, p_weekday int, p_is_open boolean, p_opens text, p_closes text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint; v_o time; v_c time;
begin
  v_salon := public._require_manager(p_token);
  if p_weekday < 0 or p_weekday > 6 then
    raise exception 'Weekday must be 0 (Sunday) to 6' using errcode = '22023';
  end if;

  begin
    v_o := p_opens::time;
    v_c := p_closes::time;
  exception when others then
    raise exception 'Times must look like 09:00' using errcode = '22023';
  end;

  if p_is_open and v_c <= v_o then
    raise exception 'Closing time must be after opening time' using errcode = '22023';
  end if;

  insert into public.salon_hours (salon_id, weekday, is_open, opens_at, closes_at)
  values (v_salon, p_weekday, p_is_open, v_o, v_c)
  on conflict (salon_id, weekday) do update
     set is_open = excluded.is_open,
         opens_at = excluded.opens_at,
         closes_at = excluded.closes_at;
end $$;


create or replace function public.admin_closures(p_token uuid)
returns table (id bigint, on_date date, reason text)
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._admin_salon(p_token);
  return query
    select c.id, c.on_date, c.reason from public.salon_closures c
     where c.salon_id = v_salon and c.on_date >= current_date - 7
     order by c.on_date;
end $$;


create or replace function public.admin_closure_set(
  p_token uuid, p_date date, p_reason text default null, p_closed boolean default true)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._require_manager(p_token);
  if p_closed then
    insert into public.salon_closures (salon_id, on_date, reason)
    values (v_salon, p_date, nullif(trim(coalesce(p_reason,'')), ''))
    on conflict (salon_id, on_date) do update set reason = excluded.reason;
  else
    delete from public.salon_closures where salon_id = v_salon and on_date = p_date;
  end if;
end $$;


create or replace function public.admin_shop(p_token uuid)
returns json
language plpgsql security definer stable set search_path = public, pg_temp as $$
declare v_salon bigint; v json;
begin
  v_salon := public._admin_salon(p_token);
  select json_build_object(
    'id', s.id, 'slug', s.slug, 'name', s.name, 'kind', s.kind,
    'category', s.category,
    'address', s.address, 'is_open', s.is_open,
    'phone_required', s.phone_required, 'currency', s.currency,
    'slot_minutes', s.slot_minutes, 'lead_minutes', s.lead_minutes,
    'horizon_days', s.horizon_days, 'active_chairs', s.active_chairs,
    'avg_service_minutes', s.avg_service_minutes, 'contact_phone', s.contact_phone)
    into v from public.salons s where s.id = v_salon;
  return v;
end $$;


-- Adding p_category gave this a new signature, so the v3.0 twelve-argument
-- version has to go explicitly: `create or replace` would leave both in
-- place and PostgREST cannot choose between ambiguous candidates.
drop function if exists public.admin_shop_save(
  uuid, text, text, text, boolean, boolean, integer, integer, integer, integer, integer, text);

create or replace function public.admin_shop_save(
  p_token uuid,
  p_name text, p_address text, p_kind text, p_is_open boolean,
  p_phone_required boolean, p_slot_minutes int, p_lead_minutes int,
  p_horizon_days int, p_active_chairs int, p_avg_minutes int,
  p_contact_phone text default null, p_category text default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_salon bigint;
begin
  v_salon := public._require_manager(p_token);

  if char_length(trim(coalesce(p_name, ''))) < 2 then
    raise exception 'Give the shop a name' using errcode = '22023';
  end if;
  if p_kind is not null and p_kind not in ('barber','salon','nails','spa','carwash') then
    raise exception 'Unknown shop type: %', p_kind using errcode = '22023';
  end if;
  if p_slot_minutes < 5 or p_slot_minutes > 120 then
    raise exception 'Slot size must be between 5 and 120 minutes' using errcode = '22023';
  end if;
  if p_active_chairs < 1 then
    raise exception 'There must be at least one chair' using errcode = '22023';
  end if;
  if p_horizon_days < 1 or p_horizon_days > 60 then
    raise exception 'Booking window must be 1 to 60 days' using errcode = '22023';
  end if;

  update public.salons
     set name = trim(p_name),
         address = nullif(trim(coalesce(p_address,'')), ''),
         kind = coalesce(p_kind, kind),
         category = coalesce(
           (select c.slug from public.categories c where c.slug = p_category),
           category),
         is_open = coalesce(p_is_open, is_open),
         phone_required = coalesce(p_phone_required, phone_required),
         slot_minutes = p_slot_minutes,
         lead_minutes = greatest(0, coalesce(p_lead_minutes, 30)),
         horizon_days = p_horizon_days,
         active_chairs = p_active_chairs,
         avg_service_minutes = greatest(5, coalesce(p_avg_minutes, 15)),
         contact_phone = nullif(trim(coalesce(p_contact_phone,'')), '')
   where id = v_salon;
end $$;


-- ============================================================
-- 10k. Directory functions  (need salons/services/staff to exist)
-- ============================================================


create or replace function public.category_list()
returns table (slug text, name text, tagline text, shop_count int)
language sql security definer stable set search_path = public, pg_temp as $$
  select c.slug, c.name, c.tagline,
         (select count(*)::int from public.salons s
           where s.category = c.slug and s.is_open)
    from public.categories c
   where c.is_active
   order by c.sort_order, c.name;
$$;


-- Replaces the v3 signature, which took no arguments.
drop function if exists public.shop_list();

create or replace function public.shop_list(p_category text default null)
returns table (
  id bigint, slug text, name text, kind text, category text,
  address text, is_open boolean, service_count int, staff_count int,
  from_price_minor int, currency text)
language sql security definer stable set search_path = public, pg_temp as $$
  select s.id, s.slug, s.name, s.kind, s.category, s.address, s.is_open,
         (select count(*)::int from public.services v
           where v.salon_id = s.id and v.is_active),
         (select count(*)::int from public.staff t
           where t.salon_id = s.id and t.is_active),
         (select min(v.price_minor)::int from public.services v
           where v.salon_id = s.id and v.is_active and v.price_minor > 0),
         s.currency
    from public.salons s
   where p_category is null or s.category = p_category
   order by s.is_open desc, s.name;
$$;


-- ============================================================
-- 11. Grants
-- ============================================================

grant usage on schema public to anon, authenticated;

grant select on public.categories    to anon, authenticated;
grant select on public.salons         to anon, authenticated;
grant select on public.salon_hours    to anon, authenticated;
grant select on public.salon_closures to anon, authenticated;
grant select on public.staff          to anon, authenticated;
grant select on public.services       to anon, authenticated;
grant select on public.staff_services to anon, authenticated;
grant select on public.waitlists      to anon, authenticated;

-- Writes happen only inside the functions above.
revoke insert, update, delete, truncate on public.categories    from anon, authenticated;
revoke insert, update, delete, truncate on public.salons         from anon, authenticated;
revoke insert, update, delete, truncate on public.salon_hours    from anon, authenticated;
revoke insert, update, delete, truncate on public.salon_closures from anon, authenticated;
revoke insert, update, delete, truncate on public.staff          from anon, authenticated;
revoke insert, update, delete, truncate on public.services       from anon, authenticated;
revoke insert, update, delete, truncate on public.staff_services from anon, authenticated;
revoke insert, update, delete, truncate on public.waitlists      from anon, authenticated;

-- Never directly reachable.
revoke all on public.appointments         from anon, authenticated;
revoke all on public.waitlist_contacts    from anon, authenticated;
revoke all on public.appointment_contacts from anon, authenticated;
revoke all on public.admins               from anon, authenticated;
revoke all on public.admin_sessions       from anon, authenticated;

revoke all on function public._admin_from_token(uuid) from public, anon, authenticated;
revoke all on function public._admin_salon(uuid)      from public, anon, authenticated;
revoke all on function public._require_manager(uuid)  from public, anon, authenticated;

do $$
declare
  fn text;
  public_fns text[] := array[
    'admin_login(text,text)',
    'admin_session(uuid)',
    'admin_logout(uuid)',
    'admin_change_password(uuid,text,text)',
    'shop_by_slug(text)',
    'shop_list(text)',
    'category_list()',
    'available_slots(bigint,date,bigint,bigint)',
    'availability_calendar(bigint,date,integer,bigint)',
    'book_appointment(bigint,bigint,timestamptz,text,text,text,bigint)',
    'appointment_status(text)',
    'cancel_appointment(text)',
    'check_in(bigint,text,text,text,timestamptz,bigint,bigint)',
    'admin_queue(uuid)',
    'admin_register_walkin(uuid,text,text,text,timestamptz,bigint,bigint)',
    'admin_set_status(uuid,bigint,text)',
    'admin_purge(uuid)',
    'admin_appointments(uuid,date,date)',
    'admin_appointment_counts(uuid,date,integer)',
    'admin_set_appointment_status(uuid,bigint,text)',
    'admin_book(uuid,bigint,timestamptz,text,text,text,bigint)',
    'admin_services(uuid)',
    'admin_service_save(uuid,bigint,text,text,text,integer,integer,boolean,integer)',
    'admin_service_retire(uuid,bigint)',
    'admin_staff(uuid)',
    'admin_staff_save(uuid,bigint,text,text,boolean,integer)',
    'admin_staff_retire(uuid,bigint)',
    'admin_hours(uuid)',
    'admin_hours_save(uuid,integer,boolean,text,text)',
    'admin_closures(uuid)',
    'admin_closure_set(uuid,date,text,boolean)',
    'admin_shop(uuid)',
    'admin_shop_save(uuid,text,text,text,boolean,boolean,integer,integer,integer,integer,integer,text,text)'
  ];
begin
  foreach fn in array public_fns loop
    execute format('revoke all on function public.%s from public', fn);
    execute format('grant execute on function public.%s to anon, authenticated', fn);
  end loop;
end $$;


-- ============================================================
-- 12. Realtime
-- ============================================================

alter table public.waitlists replica identity full;

do $$
begin
  alter publication supabase_realtime add table public.waitlists;
exception when duplicate_object then null;
end $$;


-- ============================================================
-- 13. CREATE YOUR FIRST OWNER  ← edit before running
-- ============================================================

insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
values ('admin', crypt('ChangeMe123!', gen_salt('bf', 12)), 'Front Desk', 1, 'owner')
on conflict (lower(admin_id)) do nothing;

-- Attach any owner account that has no shop yet to the first shop.
update public.admins a
   set salon_id = (select min(id) from public.salons)
 where a.salon_id is null;


-- ============================================================
-- 14. Adding another shop (this is the whole onboarding flow)
-- ============================================================
-- with s as (
--   insert into public.salons (name, slug, kind, address, active_chairs, phone_required)
--   values ('ICON Koramangala', 'koramangala', 'nails', '5th Block, Koramangala', 3, false)
--   returning id
-- )
-- insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
-- select 'kora', crypt('a-strong-password', gen_salt('bf', 12)), 'Koramangala Desk', s.id, 'owner'
--   from s;
--
-- A new shop gets the default Mon-Sat 09:00-19:00 week and the starter
-- service menu the next time this script runs. To seed them immediately,
-- just re-run this whole file — it is idempotent.


-- ============================================================
-- Verify
-- ============================================================
-- Shops:            select id, slug, name, kind from salons;
-- Shop payload:     select shop_by_slug('perimeter-center');
-- Free slots today: select * from available_slots(1, current_date, 1);
-- Login:            select admin_login('admin','ChangeMe123!');
-- Hashes hidden:    set role anon; select * from admins;        -- expect denied
-- Bookings hidden:  set role anon; select * from appointments;  -- expect denied
