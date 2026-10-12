# ICON — Live Salon Waitlist

A walk-in waitlist for a hair salon, built as static HTML with
[Supabase](https://supabase.com) Realtime. No framework, no build step beyond a
tiny script that writes your keys into a config file.

Everything is organised around one object: **the ticket**. Customers take a
numbered ticket from their phone, the lobby TV shows who's up, and the front
desk works the line.

| Page | Who uses it | What it does |
|---|---|---|
| `index.html` | Customers | Live wait, take a ticket, pick a time, watch their place update |
| `tv.html` | Lobby TV | Now serving and up next, at wall scale |
| `login.html` | Staff | Sign in with a staff ID and password |
| `admin.html` | Front desk | Register walk-ins, call people to the chair, finish or remove them |

All screens stay in sync over a websocket.

---

## Quick start

```bash
# 1. Run the database setup — paste schema.sql into
#    Supabase Dashboard -> SQL Editor -> New query -> Run

# 2. Set your keys
cp .env.example .env
#    ...open .env and fill in SUPABASE_URL and SUPABASE_KEY...

# 3. Generate config.js from .env
npm run config

# 4. Serve the folder
npm start          # -> http://localhost:3000
```

Then sign in at <http://localhost:3000/login.html> with the staff ID and
password you set in step 9 of `schema.sql`.

> **Serve over HTTP, don't open the files directly.** `file:///…` breaks
> `config.js` loading and websockets. `npm start`, `python3 -m http.server 3000`
> or VS Code Live Server all work.

---

## Setup in detail

### 1. Create a Supabase project

1. <https://supabase.com/dashboard> → **New project**.
2. Name it, set a database password, pick a region near the salon.
3. Wait ~2 minutes to provision.

### 2. Run `schema.sql`

**SQL Editor → New query →** paste all of [`schema.sql`](./schema.sql) **→ Run.**

It is safe to run on a fresh project *or* over an existing v1 install — see
[Upgrading](#upgrading-from-v1). It is idempotent, so re-running is harmless.

Before you run it, scroll to **section 9** and change the admin password:

```sql
insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
values (
  'admin',                                    -- the staff ID they type
  crypt('ChangeMe123!', gen_salt('bf', 12)),  -- <- CHANGE THIS
  'Front Desk', 1, 'owner'
);
```

`crypt()` hashes it right there in the database, so the plain text is never
stored anywhere.

### 3. Find your two keys

| Variable | Where |
|---|---|
| `SUPABASE_URL` | Settings → **Data API** → *Project URL* |
| `SUPABASE_KEY` | Settings → **API Keys** → *Publishable key* (older projects: *anon public*) |

Direct link: `https://supabase.com/dashboard/project/<your-ref>/settings/api-keys`

### 4. Fill in `.env`

```env
SUPABASE_URL=https://abcdefghijklmnop.supabase.co
SUPABASE_KEY=sb_publishable_xxxxxxxxxxxxx

SALON_ID=1
MINUTES_PER_CLIENT=15
ACTIVE_CHAIRS=1
```

### 5. Build `config.js`

```bash
npm run config
```

Browsers can't read `.env`, so this writes the values into `config.js`, which the
pages load with a `<script>` tag. Re-run it whenever `.env` changes. It also
refuses to write a secret key into a browser file.

**No Node?** `cp config.example.js config.js` and edit it by hand.

---

## About the keys

| Key | Name in dashboard | Safe in the browser? |
|---|---|---|
| Publishable | **Publishable key** / anon public | **Yes** — designed for it |
| Secret | **Secret key** / service_role | **Never.** Bypasses all security |

The publishable key is meant to ship in frontend code. What protects your data is
Row Level Security plus the database functions in `schema.sql` — not the secrecy
of this key. **There are no other keys to add**: no API key, no admin key, no
service key. Those two values are everything the app needs.

`.env` and `config.js` are both in `.gitignore`. Keep it that way.

---

## How staff login works

You asked for a custom `admins` table with a staff ID and password, and that's
what this is — no email addresses, your own table. One thing is done differently
than a naive version, deliberately:

**The password is verified inside Postgres, not in the browser.** A page that
compares passwords itself has to read the stored hash to do it, which means
anyone can read your `admins` table, or simply skip the check in devtools. So
instead:

- `admins` and `admin_sessions` have **RLS on and no policies at all**. Every
  direct query from a browser returns zero rows. Password hashes are unreachable.
- `admin_login(staff_id, password)` is a `SECURITY DEFINER` function. It hashes
  with `pgcrypto` bcrypt (cost 12), compares server-side, and on success returns
  a random session token.
- Every staff action — reading phone numbers, calling someone to the chair,
  clearing the line — goes through a function that takes that token and checks
  it. `waitlists` has **no insert, update or delete policy**, so there is no way
  to change the queue from a browser except through those functions.

Also built in:

- The same "Incorrect staff ID or password" message whether the ID exists or not,
  so the login can't be used to discover valid staff IDs.
- Five wrong attempts locks the account for 15 minutes.
- Sessions expire after 12 hours; signing out deletes the token server-side.
- `stylist` can work the line. Only `manager` and `owner` can clear it.

### Managing staff

```sql
-- add someone
insert into public.admins (admin_id, password_hash, display_name, salon_id, role)
values ('ravi', crypt('a-good-password', gen_salt('bf', 12)), 'Ravi', 1, 'stylist');

-- reset a password
update public.admins
   set password_hash = crypt('new-password', gen_salt('bf', 12)),
       failed_attempts = 0, locked_until = null
 where lower(admin_id) = 'ravi';

-- unlock after 5 bad attempts
update public.admins set failed_attempts = 0, locked_until = null
 where lower(admin_id) = 'ravi';
```

Staff can also change their own password in-app via
`ICON.admin.changePassword(current, next)`.

Staff IDs are case-insensitive — `Ravi` and `ravi` are the same login.

---

## The time section

Two different things, both on the check-in form:

**What the customer sees.** Position in line and an estimated clock time,
recomputed live from the queue:

```
ceil(people_ahead / ACTIVE_CHAIRS) × MINUTES_PER_CLIENT
```

Six people across three chairs is two rounds — 30 minutes, not 90. Nothing is
stored, so the estimate can't go stale.

**What the customer adds.** An optional preferred time, offered as the next few
half-hour slots after the current wait. Picking one stores `preferred_time` on
the ticket and shows it to the front desk ("asked for 7:30 pm"). The default,
*As soon as possible*, leaves it `NULL`.

A preferred time is a request, not a booking — it doesn't reorder the queue. If
you want real appointment slots with per-stylist availability, that's a different
feature and a bigger change.

---

## Tuning

In `.env`, then re-run `npm run config`:

| Variable | Default | Effect |
|---|---|---|
| `SALON_ID` | `1` | Which `salons` row this install serves |
| `MINUTES_PER_CLIENT` | `15` | Average haircut length |
| `ACTIVE_CHAIRS` | `1` | Chairs running now |

---

## Project layout

```
ICON/
├── index.html           Customer check-in and live ticket
├── tv.html              Lobby board
├── login.html           Staff sign-in
├── admin.html           Front desk console
├── icon.css             The whole design system
├── icon.js              Client, auth, queue maths, realtime
├── config.example.js    Manual config template
├── config.js            GENERATED — gitignored
├── .env.example         Env template with key-finding instructions
├── .env                 Your keys — gitignored
├── schema.sql           Tables, functions, RLS, realtime, first admin
├── vercel.json          Tells Vercel to run the config build
├── scripts/
│   └── build-config.js  .env (or process.env) -> config.js
└── package.json
```

`icon.js` holds everything shared: the Supabase client, HTML escaping, phone
formatting, the wait maths, the realtime subscription with its polling fallback,
and the `ICON.auth` / `ICON.admin` wrappers around the database functions.

---

## Data model

```
salons ──┬── waitlists ─── waitlist_contacts   (phone numbers, staff-only)
         └── admins ─── admin_sessions
```

`waitlists` is the only table a browser reads directly, because Realtime needs
table-level read access to deliver change events. **Realtime filters rows by RLS
but not columns** — anyone who can see a row receives every column over the
websocket. So phone numbers live in `waitlist_contacts`, which no browser can
read at all; staff get them through `admin_queue()`.

A ticket moves through four states:

```
waiting ──[Call to chair]──> in_chair ──[Finished]──> done
   │                             │
   └─────────[Remove]────────────┴─────────────────> cancelled
```

Nothing is ever hard-deleted, so you keep a full day's history. Only `waiting`
and `in_chair` rows from today appear on screen.

Ticket numbers restart at 1 each day per salon, allocated under an advisory lock
so two simultaneous check-ins can't collide. One active ticket per phone number
per day.

---

## Upgrading from v1

Run `schema.sql`. It detects the old shape and migrates in place:

- adds `ticket_no`, `service_date` and `preferred_time` to `waitlists`
- backfills `service_date` from `join_time`, and numbers existing tickets per day
  in join order
- creates `waitlist_contacts`, copies every `phone_number` across, then drops the
  old column
- drops the permissive v1 `dev open *` policies
- creates `admins`, `admin_sessions` and all the functions

No rows are deleted and it's safe to re-run. This was tested against a seeded v1
database: all rows survived with correct per-day ticket numbers.

Your old `admin.html` bookmark now redirects to `login.html`.

---

## Deploying to Vercel

`config.js` is gitignored, so it isn't in your repo — Vercel generates it during
the build. Two things make that work, both already in the project:

- `vercel.json` sets the build command to `node scripts/build-config.js` and the
  output directory to `.`
- `package.json` has a matching `build` script

`build-config.js` reads real environment variables first and falls back to `.env`,
so the same script works locally and in a hosted build.

### Steps

1. Push to GitHub.
2. Vercel → **Add New → Project**, import the repo, framework preset **Other**.
   Leave the build settings alone; `vercel.json` handles them.
3. **Settings → Environment Variables** — add these two, spelled exactly:

   | Name | Value |
   |---|---|
   | `SUPABASE_URL` | `https://<your-ref>.supabase.co` |
   | `SUPABASE_KEY` | your **publishable** key |

   Tick **Production**, **Preview** and **Development** for both. Optionally add
   `SALON_ID`, `MINUTES_PER_CLIENT`, `ACTIVE_CHAIRS`.
4. **Deploy.** The build log should show:

   ```
   ✓ Wrote config.js  (hosted build)
     SUPABASE_URL : https://....supabase.co   [from environment]
     SUPABASE_KEY : sb_publi…xxxx   [from environment]
   ```

> **Environment variables are read at build time.** Adding or editing one does
> not fix a deployment that already finished — you must redeploy:
> **Deployments → ⋯ → Redeploy**, with "Use existing Build Cache" unticked.

### Verify

Open `https://your-app.vercel.app/config.js`. You should see your
`window.ICON_CONFIG = { … }`. A 404 means the build command didn't run — check
the build log for the `✓ Wrote config.js` line.

If a variable name is misspelled, the build log says so and lists the names it
can actually see.

### Netlify

Build command `node scripts/build-config.js`, publish directory `.`, same two
variables under **Site configuration → Environment variables**.

### Lobby TV

Point a browser at `tv.html` fullscreen (`F11`) with sleep disabled. A Raspberry
Pi in kiosk mode works well. The board reconnects on its own and refreshes every
30 seconds even if the websocket drops.

---

## Security notes

What's in place:

- Password hashes, session tokens and phone numbers are unreachable from any
  browser (RLS enabled, no policies, functions only).
- The queue cannot be modified without a valid session token — there is no
  insert/update/delete policy on `waitlists` at all.
- Every value rendered to a page goes through `ICON.esc()`, so a customer who
  checks in as `<img onerror=…>` shows up as text, not script.
- The lobby board shows a first name and last initial, never a phone number or
  cut notes.
- Login is rate-limited and doesn't leak which staff IDs exist.

Worth knowing:

- The session token is kept in `localStorage`. That's standard for an app with no
  backend, but it means a browser extension or an XSS hole could read it. The
  escaping above is what keeps that shut; keep it in place if you edit the pages.
- `check_in` is open to the public by design, so someone could script fake
  tickets. The one-per-phone-per-day rule limits it. If it becomes a problem, add
  a captcha (Cloudflare Turnstile) in front of `check_in`.
- Sessions last 12 hours and are not sliding. A long shift means signing in again.

---

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| Red bar: "config.js is missing or empty" | No `config.js` | `cp .env.example .env`, fill it in, `npm run config` |
| Red bar **only on Vercel** | `config.js` never generated in the build | Confirm `vercel.json` is committed, then **redeploy** |
| Red bar: "supabase-js did not load" | No internet, or CDN blocked | Check the `<script>` tag in `<head>` |
| Build log: "No .env file found" | Old `build-config.js` | Use the version that reads `process.env` |
| Login says "Incorrect staff ID or password" with the right one | Admin row never created, or locked out | Run section 9 of `schema.sql`; check `locked_until` |
| "function admin_login does not exist" | `schema.sql` didn't finish | Re-run it; check for errors in the SQL Editor |
| Signed in, but the queue is empty and the console shows 42501 | Grants missing | Re-run section 7 of `schema.sql` |
| Updates take 30s instead of being instant | Realtime not enabled | Re-run section 8, or Database → Replication → add `waitlists` |
| "relation public.waitlists does not exist" | Schema never ran | Run `schema.sql` |
| Check-in says "already has a ticket today" | Working as intended | Finish or remove that person first |
| Everything unstyled | Opened via `file://` | Serve over HTTP — `npm start` |

Every error also prints to the browser console with an `[ICON]` prefix.

---

## Design

A ticket, not a dashboard. The palette is barber-pole DNA cooled off — enamel ink
`#141A2E`, porcelain `#EDEEF0`, chrome, one barber red `#D8232A` reserved for
"pay attention", one green `#0F9B6C` for "moving". Anton sets the ticket numerals
and the wordmark; Archivo with tabular figures does everything else, so numbers
don't wobble as they tick over. The only thing that animates on its own is a
ticket being issued.

---

## License

MIT
