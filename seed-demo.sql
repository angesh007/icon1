-- ============================================================
-- ICON — demo data
--
-- Nine shops across the three categories, each with its own team,
-- its own service menu, its own hours and its own owner login.
-- Enough to click through the whole directory and test that one
-- owner cannot see another's shop.
--
-- Run AFTER schema.sql. Safe to re-run: it updates in place.
--
--   ICON
--   |- barbers      -> fade-factory, the-barber-room, crown-cuts
--   |- nail-salon   -> polish-bar, luxe-nails, the-nail-studio
--   `- car-wash     -> shine-express, aqua-detail, foam-garage
--
-- Every login below is  <staff id> / Demo@2026
-- CHANGE OR DELETE THESE BEFORE GOING ANYWHERE NEAR REAL CUSTOMERS.
-- ============================================================

set search_path = public, extensions;

do $$
declare
  v_pw   text := 'Demo@2026';
  v_shop bigint;
  r      record;
  t      record;
begin

  -- ----------------------------------------------------------
  -- Every shop in one table: the whole demo set is data, so
  -- adding a tenth shop is one more row rather than more code.
  -- ----------------------------------------------------------
  for r in
    select * from (values
      -- slug, name, category, kind, address, chairs, avg_min, slot_min, phone_req, admin_id, admin_name, currency
      ('fade-factory',    'Fade Factory',     'barbers',    'barber',  '12 Indiranagar 100ft Rd, Bengaluru', 3, 30, 30, false, 'fade',   'Fade Factory Desk', '₹'),
      ('the-barber-room', 'The Barber Room',  'barbers',    'barber',  '7 Koramangala 5th Block, Bengaluru', 2, 30, 30, false, 'room',   'Barber Room Desk',  '₹'),
      ('crown-cuts',      'Crown Cuts',       'barbers',    'barber',  '45 Jayanagar 4th Block, Bengaluru',  4, 25, 15, true,  'crown',  'Crown Cuts Desk',   '₹'),

      ('polish-bar',      'Polish Bar',       'nail-salon', 'nails',   '3 Church St, Bengaluru',             3, 45, 30, false, 'polish', 'Polish Bar Desk',   '₹'),
      ('luxe-nails',      'Luxe Nails',       'nail-salon', 'nails',   '88 HSR Layout Sector 2, Bengaluru',  2, 60, 30, true,  'luxe',   'Luxe Nails Desk',   '₹'),
      ('the-nail-studio', 'The Nail Studio',  'nail-salon', 'nails',   '21 Whitefield Main Rd, Bengaluru',   4, 45, 30, false, 'studio', 'Nail Studio Desk',  '₹'),

      ('shine-express',   'Shine Express',    'car-wash',   'carwash', '9 Hosur Rd, Bengaluru',              2, 40, 30, false, 'shine',  'Shine Express Desk','₹'),
      ('aqua-detail',     'Aqua Detail',      'car-wash',   'carwash', '60 Outer Ring Rd, Bengaluru',        3, 60, 60, true,  'aqua',   'Aqua Detail Desk',  '₹'),
      ('foam-garage',     'Foam Garage',      'car-wash',   'carwash', '14 Bannerghatta Rd, Bengaluru',      1, 45, 30, false, 'foam',   'Foam Garage Desk',  '₹')
    ) as x(slug, name, category, kind, address, chairs, avg_min, slot_min, phone_req, admin_id, admin_name, currency)
  loop

    -- ---------- the shop ----------
    insert into public.salons
      (slug, name, category, kind, address, active_chairs, avg_service_minutes,
       slot_minutes, lead_minutes, horizon_days, phone_required, currency, is_open)
    values
      (r.slug, r.name, r.category, r.kind, r.address, r.chairs, r.avg_min,
       r.slot_min, 15, 30, r.phone_req, r.currency, true)
    on conflict (lower(slug)) do update
      set name = excluded.name, category = excluded.category, kind = excluded.kind,
          address = excluded.address, active_chairs = excluded.active_chairs,
          avg_service_minutes = excluded.avg_service_minutes,
          slot_minutes = excluded.slot_minutes, horizon_days = excluded.horizon_days,
          phone_required = excluded.phone_required
    returning id into v_shop;

    if v_shop is null then
      select id into v_shop from public.salons where slug = r.slug;
    end if;

    -- ---------- hours ----------
    -- Barbers and nail salons rest on Monday; car washes open all week.
    delete from public.salon_hours where salon_id = v_shop;
    insert into public.salon_hours (salon_id, weekday, is_open, opens_at, closes_at)
    select v_shop, d.wd,
           case
             when r.category = 'car-wash' then true
             when d.wd = 1 then false          -- Monday closed
             else true
           end,
           case when r.category = 'car-wash' then '08:00'::time else '10:00'::time end,
           case when r.category = 'car-wash' then '19:00'::time else '20:00'::time end
      from (select generate_series(0, 6) as wd) d;

    -- ---------- team ----------
    delete from public.staff where salon_id = v_shop;
    for t in
      select * from (values
        ('fade-factory',    'Imran',  'Master barber',  1),
        ('fade-factory',    'Sachin', 'Barber',         2),
        ('fade-factory',    'Deepak', 'Barber',         3),

        ('the-barber-room', 'Arjun',  'Senior barber',  1),
        ('the-barber-room', 'Nikhil', 'Barber',         2),

        ('crown-cuts',      'Rahul',  'Master barber',  1),
        ('crown-cuts',      'Vikram', 'Barber',         2),
        ('crown-cuts',      'Sameer', 'Barber',         3),
        ('crown-cuts',      'Joseph', 'Apprentice',     4),

        ('polish-bar',      'Ananya', 'Nail artist',    1),
        ('polish-bar',      'Divya',  'Nail artist',    2),
        ('polish-bar',      'Fatima', 'Nail technician',3),

        ('luxe-nails',      'Reshma', 'Lead nail tech', 1),
        ('luxe-nails',      'Kavya',  'Nail technician',2),

        ('the-nail-studio', 'Sneha',  'Nail artist',    1),
        ('the-nail-studio', 'Pooja',  'Nail artist',    2),
        ('the-nail-studio', 'Lakshmi','Pedicure spec.', 3),
        ('the-nail-studio', 'Zoya',   'Nail technician',4),

        ('shine-express',   'Manoj',  'Wash crew',      1),
        ('shine-express',   'Ganesh', 'Wash crew',      2),

        ('aqua-detail',     'Suresh', 'Detailer',       1),
        ('aqua-detail',     'Irfan',  'Detailer',       2),
        ('aqua-detail',     'Babu',   'Wash crew',      3),

        ('foam-garage',     'Prakash','Owner, detailer',1)
      ) as y(shop, name, title, ord)
      where y.shop = r.slug
    loop
      insert into public.staff (salon_id, name, title, is_active, sort_order)
      values (v_shop, t.name, t.title, true, t.ord);
    end loop;

    -- ---------- services ----------
    delete from public.services where salon_id = v_shop;

    if r.category = 'barbers' then
      insert into public.services
        (salon_id, name, audience, category, duration_minutes, price_minor, sort_order)
      values
        (v_shop, 'Haircut',              'men',    'hair',  30, 25000, 1),
        (v_shop, 'Haircut & beard',      'men',    'hair',  45, 40000, 2),
        (v_shop, 'Beard trim & shape',   'men',    'beard', 20, 15000, 3),
        (v_shop, 'Hot towel shave',      'men',    'beard', 30, 30000, 4),
        (v_shop, 'Kids haircut',         'kids',   'hair',  20, 18000, 5),
        (v_shop, 'Head massage',         'unisex', 'spa',   20, 25000, 6);

    elsif r.category = 'nail-salon' then
      insert into public.services
        (salon_id, name, audience, category, duration_minutes, price_minor, sort_order)
      values
        (v_shop, 'Classic manicure',     'women',  'nails', 45,  50000, 1),
        (v_shop, 'Classic pedicure',     'women',  'nails', 60,  70000, 2),
        (v_shop, 'Gel nails',            'women',  'nails', 75,  95000, 3),
        (v_shop, 'Gel removal & refill', 'women',  'nails', 60,  65000, 4),
        (v_shop, 'Nail art, per hand',   'women',  'nails', 30,  40000, 5),
        (v_shop, 'Mens grooming mani',   'men',    'nails', 30,  35000, 6),
        (v_shop, 'Kids mini mani',       'kids',   'nails', 20,  25000, 7),
        (v_shop, 'Paraffin hand spa',    'unisex', 'skin',  30,  45000, 8);

    else  -- car-wash: the "audience" step has nothing to ask, so every
          -- service is unisex and the vehicle is in the name instead.
      insert into public.services
        (salon_id, name, audience, category, duration_minutes, price_minor, sort_order)
      values
        (v_shop, 'Express wash, hatchback', 'unisex', 'other',  30,  30000, 1),
        (v_shop, 'Express wash, sedan',     'unisex', 'other',  40,  40000, 2),
        (v_shop, 'Express wash, SUV',       'unisex', 'other',  50,  55000, 3),
        (v_shop, 'Wash & interior vacuum',  'unisex', 'other',  60,  75000, 4),
        (v_shop, 'Wax & polish',            'unisex', 'other',  90, 150000, 5),
        (v_shop, 'Full detail',             'unisex', 'other', 180, 350000, 6),
        (v_shop, 'Underbody wash',          'unisex', 'other',  20,  25000, 7);
    end if;

    -- ---------- owner login ----------
    insert into public.admins
      (admin_id, password_hash, display_name, salon_id, role)
    values
      (r.admin_id, crypt(v_pw, gen_salt('bf', 12)), r.admin_name, v_shop, 'owner')
    on conflict (lower(admin_id)) do update
      set password_hash = crypt(v_pw, gen_salt('bf', 12)),
          display_name = excluded.display_name,
          salon_id = excluded.salon_id,
          role = excluded.role,
          failed_attempts = 0,
          locked_until = null;

    raise notice 'seeded % (%) - shop id %', r.name, r.category, v_shop;
  end loop;
end $$;


-- ------------------------------------------------------------
-- One stylist-level login, to check the role restrictions:
-- can work the line, cannot touch services, team or hours.
-- ------------------------------------------------------------
insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
select 'imran', crypt('Demo@2026', gen_salt('bf', 12)), 'Imran', s.id, 'stylist'
  from public.salons s where s.slug = 'fade-factory'
on conflict (lower(admin_id)) do update
  set password_hash = crypt('Demo@2026', gen_salt('bf', 12)),
      salon_id = excluded.salon_id, role = 'stylist',
      failed_attempts = 0, locked_until = null;


-- ------------------------------------------------------------
-- A few bookings and walk-ins so the screens aren't empty.
-- ------------------------------------------------------------
do $$
declare
  v_shop bigint;
  v_svc  bigint;
  v_when timestamptz;
  i int;
begin
  -- Walk-ins at Fade Factory, today
  select id into v_shop from public.salons where slug = 'fade-factory';
  if not exists (select 1 from public.waitlists
                  where salon_id = v_shop and service_date = current_date) then
    select id into v_svc from public.services
     where salon_id = v_shop order by sort_order limit 1;
    perform public.check_in(v_shop, 'Rohit Menon', '9845010001', '#2 fade, square back', null, v_svc, null);
    perform public.check_in(v_shop, 'Arun Pillai', null, null, null, v_svc, null);
    perform public.check_in(v_shop, 'Kiran Rao',  '9845010003', 'scissors only', null, v_svc, null);
    -- put the first one in the chair
    update public.waitlists set status = 'in_chair', called_at = now()
     where salon_id = v_shop and service_date = current_date
       and ticket_no = 1;
  end if;

  -- Bookings spread over the next week at Polish Bar
  select id into v_shop from public.salons where slug = 'polish-bar';
  select id into v_svc from public.services
   where salon_id = v_shop and name = 'Gel nails' limit 1;

  -- Guard on the bookings too, or re-running the seed stacks duplicates.
  if v_svc is not null
     and not exists (select 1 from public.appointments
                      where salon_id = v_shop and on_date >= current_date) then
    for i in 1..6 loop
      -- 11:00, 13:00, 15:00 on alternating days
      v_when := (current_date + i) + (time '11:00' + ((i % 3) * interval '2 hours'));
      begin
        perform public.book_appointment(
          v_shop, v_svc, v_when,
          (array['Meera S','Tanvi R','Ishita K','Nandini P','Aarti B','Shruti M'])[i],
          (array['9845020001','9845020002',null,'9845020004',null,'9845020006'])[i],
          null, null);
      exception when others then
        raise notice 'skipped a demo booking: %', sqlerrm;
      end;
    end loop;
  end if;

  -- A couple of car-wash bookings
  select id into v_shop from public.salons where slug = 'shine-express';
  select id into v_svc from public.services
   where salon_id = v_shop and name like 'Express wash, SUV%' limit 1;
  if v_svc is not null
     and not exists (select 1 from public.appointments
                      where salon_id = v_shop and on_date >= current_date) then
    begin
      perform public.book_appointment(v_shop, v_svc,
        (current_date + 1) + time '09:00', 'Vikas Hegde', '9845030001', 'KA-01-AB-1234', null);
      perform public.book_appointment(v_shop, v_svc,
        (current_date + 2) + time '10:30', 'Priya Nair', null, 'white Creta', null);
    exception when others then
      raise notice 'skipped a demo car-wash booking: %', sqlerrm;
    end;
  end if;
end $$;


-- ============================================================
-- What you just created
-- ============================================================
select c.name as category,
       s.slug,
       s.name,
       (select count(*) from public.staff t where t.salon_id = s.id and t.is_active) as team,
       (select count(*) from public.services v where v.salon_id = s.id and v.is_active) as services,
       s.phone_required as phone_req,
       (select string_agg(a.admin_id, ', ') from public.admins a where a.salon_id = s.id) as logins
  from public.salons s
  join public.categories c on c.slug = s.category
 order by c.sort_order, s.name;

-- Every login above uses the password  Demo@2026
--
-- To remove all of this again:
--   delete from public.admins where admin_id in
--     ('fade','room','crown','polish','luxe','studio','shine','aqua','foam','imran');
--   delete from public.salons where slug in
--     ('fade-factory','the-barber-room','crown-cuts','polish-bar','luxe-nails',
--      'the-nail-studio','shine-express','aqua-detail','foam-garage');
