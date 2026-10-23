# ICON — Salon queue & bookings

A walk-in queue **and** an appointment calendar for local service shops, built as
static HTML with [Supabase](https://supabase.com). One deployment serves many
shops across several categories; each shop gets its own link and QR code.

```
ICON
├── barbers       -> Fade Factory, The Barber Room, Crown Cuts
├── nail-salon    -> Polish Bar, Luxe Nails, The Nail Studio
└── car-wash      -> Shine Express, Aqua Detail, Foam Garage
```

A customer arriving without a shop in the URL browses that tree: category, then
shop, then book. A customer scanning a shop's QR code lands straight on it and
never sees the directory.

| Page | Who | What it does |
|---|---|---|
| `index.html` | Customers | Tap through: queue now or book later, who it's for, service, time |
| `tv.html` | Lobby screen | Now serving and up next, with a back link and kiosk mode |
| `login.html` | Staff | Sign in with a staff ID and password |
| `admin.html` | Shop owner | Line, calendar, services, team, hours, QR code, settings |

Everything is organised around one object: the ticket. Walk-ins get a number;
bookings get a time.

---

## Quick start

```bash
# 1. Database: paste schema.sql into Supabase -> SQL Editor -> Run
#    EDIT SECTION 13 FIRST — change the default admin password

# 2. Demo data (optional, recommended for testing):
#    paste seed-demo.sql -> Run.  Nine shops with their own teams.

# 3. Keys
cp .env.example .env     # fill in SUPABASE_URL and SUPABASE_KEY
npm run config

# 4. Serve
npm start                # -> http://localhost:3000
```

Open `/` to browse the directory, or sign in at `/login.html` and print the QR
code from the **QR code** tab.

> Serve over HTTP. Opening `file:///…` breaks `config.js` and websockets.

---

## Demo data

`seed-demo.sql` creates nine shops — three per category — each with its own
team, service menu, opening hours and owner login. It is idempotent, so
re-running it updates rather than duplicating.

| Category | Shops | Team sizes |
|---|---|---|
| Barbers | Fade Factory, The Barber Room, Crown Cuts | 3, 2, 4 |
| Nail salons | Polish Bar, Luxe Nails, The Nail Studio | 3, 2, 4 |
| Car wash | Shine Express, Aqua Detail, Foam Garage | 2, 3, 1 |

Logins are `fade`, `room`, `crown`, `polish`, `luxe`, `studio`, `shine`, `aqua`,
`foam` — all with the password `Demo@2026`. Plus `imran`, a **stylist** at Fade
Factory, for checking the role restrictions.

It also seeds a few walk-ins and bookings so the screens aren't empty, varies
the settings (Crown Cuts, Luxe Nails and Aqua Detail require a phone number;
car washes open all week while the others close Mondays), and prints a summary
table when it finishes.

**Delete these before real customers.** The removal SQL is at the bottom of the
file.


## What's new in v3

- **Many shops, one deployment.** Each shop has a `slug`; customers land on
  `?shop=<slug>`. An owner signs in and sees only their own shop.
- **Services with an audience.** Men / women / kids / unisex, each with its own
  duration and price. Customers tap "Who's it for?" then pick from a menu.
- **Appointments.** A real calendar with slots computed from opening hours, team
  size and existing bookings. Walk-in queue still works alongside it.
- **Owner self-service.** Add services, team, opening hours and closures from the
  console. No SQL needed after setup.
- **QR code generator.** Drawn on the device, printable, downloadable.
- **Phone numbers optional**, with a per-shop toggle to require them.
- **Board has a header and a back link** — it used to be a dead end.
- **A category directory**: barbers, nail salons and car washes, browsable when
  no shop is named in the URL.
- **A month calendar** for both the customer and the owner, so today and every
  date in the booking window are reachable — the old day strip hid anything past
  the next fortnight.
- **The desk can take a phone booking** for any future date from the calendar
  tab, using the same availability the customer sees.

---

## The customer flow

Tap-first. The only typing is a name (and optionally a phone and a note).

```
no ?shop= ──> Category ──> Shop ──┐
                                  │
?shop=slug (QR) ──────────────────┤
                                  v
            ┌─ Join the queue now ──┐
Shop page ──┤                       ├── Who's it for? ── Service ──┐
            └─ Book a slot later ───┘         (skipped if only      │
                                               one applies)        │
                                                                   │
   queue ───────────────────────────────────────────────────────────┤
                                                                   │
   book ──── Month calendar ── Time ─────────────────────────────────┤
                                                                   │
                                            Name (+ optional phone) ┘
                                                        │
                              ┌─────────────────────────┴──────────┐
                              │                                    │
                     live ticket, updating            booking confirmation
                     with position and ETA            with a reference code
```

Both outcomes persist in the browser, so reopening the link shows the live
ticket or the booking rather than starting over.

---

## Setup in detail

### 1. Create a Supabase project

<https://supabase.com/dashboard> → **New project**. Pick a region near the shops.

### 2. Run `schema.sql`

**SQL Editor → New query →** paste all of [`schema.sql`](./schema.sql) → **Run**.

Safe on a fresh project *or* over a v1/v2 install — it migrates in place and is
idempotent. Before running, edit **section 13** and change the password:

```sql
insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
values ('admin', crypt('ChangeMe123!', gen_salt('bf', 12)), 'Front Desk', 1, 'owner');
```

`crypt()` hashes it in the database, so the plain text is never stored.

### 3. Your two keys

| Variable | Where |
|---|---|
| `SUPABASE_URL` | Settings → **Data API** → *Project URL* |
| `SUPABASE_KEY` | Settings → **API Keys** → *Publishable key* |

`https://supabase.com/dashboard/project/<your-ref>/settings/api-keys`

**There is no third key.** Staff passwords live in the `admins` table and are
checked inside Postgres. Never put the secret / service_role key in this project.

### 4. `.env` → `config.js`

```env
SUPABASE_URL=https://abcdefghijklmnop.supabase.co
SUPABASE_KEY=sb_publishable_xxxxxxxxxxxxx
SALON_ID=1              # fallback shop when no ?shop= is given
```

```bash
npm run config
```

Browsers can't read `.env`, so this writes the values into `config.js`. On Vercel
the build does it from the dashboard's environment variables instead.

---

## Adding a shop

Two inserts. The next run of `schema.sql` gives it a default week and a starter
service menu, or just re-run the whole file.

```sql
with s as (
  insert into public.salons (name, slug, kind, address, active_chairs, phone_required)
  values ('ICON Koramangala', 'koramangala', 'nails', '5th Block, Koramangala', 3, false)
  returning id
)
insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
select 'kora', crypt('a-strong-password', gen_salt('bf', 12)), 'Koramangala Desk', s.id, 'owner'
  from s;
```

That shop is now at `?shop=koramangala`, and `kora` sees only its data. The owner
prints their own QR code from the console.

`category` is what the directory groups by: `barbers`, `nail-salon` or
`car-wash`. `kind` (`barber`, `salon`, `nails`, `spa`, `carwash`) is just a
label. Neither changes behaviour — every shop gets both the queue and the
calendar. Owners can move their own shop between categories in the Shop tab.

To add a category, insert a row into `categories` and it appears in the
directory as soon as a shop points at it:

```sql
insert into public.categories (slug, name, tagline, sort_order)
values ('pet-grooming', 'Pet grooming', 'Wash, clip and nails', 4);
```

---

## How slots are worked out

`available_slots()` returns only **free** start times, so no customer ever learns
who else is booked:

1. Start from that weekday's opening hours. Closed day, or a date in
   `salon_closures` → no slots.
2. Step through the day in `slot_minutes` steps (default 30).
3. Drop any start where the service wouldn't finish before closing — a 75-minute
   service in a shop closing at 19:00 stops being offered at 17:30.
4. Capacity per slot = number of active team members. Subtract overlapping
   bookings. Nothing left → the slot disappears.
5. Hide anything sooner than `lead_minutes` from now.

So **the team list is the capacity**: three active people means three bookings per
slot. Marking someone away immediately narrows availability.

Booking takes a per-shop advisory lock and re-checks availability inside the
transaction, so two people tapping the last slot at the same moment can't both
get it — the second sees "That time has just been taken."

The walk-in wait estimate is separate:
`ceil(people_waiting / active_chairs) × avg_service_minutes`.

---

## The owner console

| Tab | What it's for | Who |
|---|---|---|
| **The line** | Today's walk-ins, call to chair, finish, remove, walk-in desk | everyone |
| **Calendar** | Month grid with booking counts; per-day list; take a booking for any future date; arrived → in chair → finished | everyone |
| **Services** | Add and edit services: audience, type, duration, price | manager/owner |
| **Team** | Add people, mark away. This sets booking capacity | manager/owner |
| **Hours** | Per-weekday open/close, plus days closed | manager/owner |
| **QR code** | Print, download, copy the link | everyone |
| **Shop** | Name, address, category, phone-required toggle, slot size, notice, booking window, own password | manager/owner |

A `stylist` sees only The line, Calendar and QR code — and the restriction is
enforced in the database, not just hidden in the UI.

Prices are entered in rupees and stored as paise (`price_minor`), so there's no
floating-point drift. Change `currency` on the `salons` row for other symbols.

Services and team members are never deleted, only switched off, so old bookings
keep their names.

---

## Optional phone numbers

Off by default: a customer can join the queue or book with just a name. Turn
**Mobile number required** on in the Shop tab for a shop that needs to call
people. Either way a number that *is* entered must be 10–15 digits.

Duplicate protection only applies when there's a number to compare, so several
anonymous walk-ins are fine.

---

## Deploying to Vercel

`config.js` is gitignored, so Vercel generates it at build time. Both pieces ship
in the project already: `vercel.json` sets the build command, and `package.json`
has a matching `build` script.

1. Push to GitHub, import in Vercel, framework preset **Other**.
2. **Settings → Environment Variables** — add `SUPABASE_URL` and `SUPABASE_KEY`,
   ticking **Production**, **Preview** and **Development**.
3. Deploy. The log should show `✓ Wrote config.js  (hosted build)`.

> **Environment variables are read at build time.** Adding one does not fix a
> finished deployment — redeploy with "Use existing Build Cache" unticked.

Check `https://your-app.vercel.app/config.js` shows your `window.ICON_CONFIG`.
A 404 means the build command didn't run.

### The lobby screen

`tv.html?shop=<slug>&kiosk=1` hides the navigation for a wall display. Press
**Escape** to bring it back. The board reconnects on its own and polls every 30
seconds if the websocket drops.

---

## Data model

```
categories ── salons

salons ──┬── salon_hours          (one row per weekday)
         ├── salon_closures       (one-off closed dates)
         ├── staff                (= booking capacity)
         ├── services ── staff_services
         ├── waitlists ────────── waitlist_contacts      (phones, staff-only)
         ├── appointments ─────── appointment_contacts   (phones, staff-only)
         └── admins ───────────── admin_sessions
```

`waitlists` is the only table a browser reads directly, because Realtime needs
table-level read access to deliver change events. **Realtime filters rows by RLS
but not columns**, so anything left on that table is readable by every visitor —
which is why phone numbers live in separate tables no browser can read at all,
and why `appointments` has no read policy. Customers see availability through
`available_slots()` and their own booking through a `lookup_code`.

States:

```
waiting ──[Call to chair]──> in_chair ──[Finished]──> done
booked ──[Arrived]──> arrived ──[In the chair]──> in_chair ──[Finished]──> done
   │                                                   │
   └──────────────[Cancel]─────────────────────────────┴──> cancelled / no_show
```

Nothing is hard-deleted. Ticket numbers restart daily per shop, allocated under
an advisory lock.

---

## Security

What's in place:

- Password hashes, session tokens, phone numbers and the whole `appointments`
  table are unreachable from any browser — RLS on with no policy, plus explicit
  `revoke`, so even with RLS accidentally disabled the grants still block it.
- Every write goes through a `SECURITY DEFINER` function that checks a session
  token and scopes to the signed-in shop. Verified: owner A cannot read, change
  or cancel anything belonging to shop B.
- Role checks live in the database. A `stylist` calling `admin_service_save`
  directly is refused.
- Everything rendered goes through `ICON.esc()`.
- The lobby board shows a first name and last initial only.
- Login is rate-limited (5 attempts → 15 minutes) and doesn't reveal which staff
  IDs exist.
- QR codes are generated on-device; the shop's URL never goes to a third party.

Worth knowing:

- The session token lives in `localStorage`. Standard for a backend-less app, but
  it means the output escaping is load-bearing — keep `ICON.esc()` if you edit.
- `check_in` and `book_appointment` are public by design, so someone could script
  fake bookings. Add a captcha in front of them if that becomes real.
- Sessions last 12 hours and are not sliding.

---

## Project layout

```
ICON/
├── index.html           Customer wizard
├── tv.html              Lobby board
├── login.html           Staff sign-in
├── admin.html           Owner console (7 tabs)
├── icon.css             The whole design system
├── customer.css         Customer page styles (index.html only)
├── board.css            Live Board styles (tv.html only)
├── icon.js              Client, shop resolution, slots, auth, owner CRUD
├── schema.sql           Tables, functions, RLS, realtime, first owner
├── seed-demo.sql        Nine demo shops with their own teams
├── vendor/qrcode.js     Vendored QR encoder (MIT) — no CDN needed
├── config.example.js    Manual config template
├── config.js            GENERATED — gitignored
├── .env.example         Env template
├── vercel.json          Build command for Vercel
└── scripts/build-config.js
```

---

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| "config.js is missing or empty" | No `config.js` | `npm run config`, or set Vercel env vars and redeploy |
| Red bar only on Vercel | Build didn't generate config | Check `vercel.json` is committed, then redeploy |
| "function crypt(text, text) does not exist" | pgcrypto not on the function's search path | Re-run `schema.sql` — section 0 handles this |
| "Shop not found" | Bad or missing `?shop=` slug | `select slug from salons;` and use one of those |
| No slots on any day | No active team, or hours closed | Add someone in **Team**; check **Hours** |
| Slots stop early in the day | Service too long to finish before closing | Expected — shorten it or extend hours |
| Login refused with the right password | Admin row missing, or locked out | Run section 13; check `locked_until` |
| Signed in but empty, console shows 42501 | Grants missing | Re-run section 11 of `schema.sql` |
| Queue updates take 30s | Realtime not enabled | Re-run section 12, or Database → Replication |
| QR tab says the library didn't load | `vendor/` not deployed | Confirm `vendor/qrcode.js` is committed |
| Everything unstyled | Opened via `file://` | Serve over HTTP |
| Directory shows nothing | No shop has a category, or none are open | `select slug, category, is_open from salons;` |
| A category is missing from the list | It has no open shops | The directory hides empty categories |
| "Unknown shop type: carwash" | Running a pre-v3.1 `schema.sql` | Re-run the current one |
| Next month greyed out on the calendar | Past the shop's booking window | Raise **How far ahead** in the Shop tab |

Errors print to the browser console with an `[ICON]` prefix.

---

## Design

A ticket, not a dashboard. Enamel ink `#141A2E`, cool porcelain `#EDEEF0`,
chrome, one barber red `#D8232A` for *attention* and one green `#0F9B6C` for
*moving*. Anton sets ticket numerals and the wordmark; Archivo with tabular
figures does everything else so numbers don't wobble as they tick. The only
unprompted animation is a ticket being issued.

---

## License

MIT. `vendor/qrcode.js` is qrcode-generator by Kazuhiko Arase, also MIT.
