# ICON — Live Salon Waitlist

A three-screen walk-in waitlist for a hair salon, built as static HTML with
[Supabase](https://supabase.com) Realtime. No build step, no framework.

| Page | Who uses it | What it does |
|---|---|---|
| `index.html` | Customers | Shows the live wait time, lets people check in from their phone |
| `admin.html` | Front desk / stylists | Register walk-ins, call clients to the chair, finish or remove them |
| `tv.html` | Lobby TV | Full-screen board — who's in the chair, who's next, estimated wait |

All three stay in sync over a websocket. Check someone in on one screen and the
other two update instantly.

---

## Quick start

```bash
# 1. Install nothing — just get the files
cd ICON

# 2. Create the database (see step 2 below for where to paste schema.sql)

# 3. Set your keys
cp .env.example .env
#    ...open .env and fill in SUPABASE_URL and SUPABASE_KEY...

# 4. Generate config.js from .env
npm run config

# 5. Serve the folder
npm start          # → http://localhost:3000
```

Then open:

- <http://localhost:3000/index.html> — customer check-in
- <http://localhost:3000/admin.html> — stylist console
- <http://localhost:3000/tv.html> — lobby board

> **You must serve over HTTP, not open the files directly.** Opening
> `file:///.../index.html` breaks `config.js` loading and websockets. Any static
> server works — `npm start`, `python3 -m http.server 3000`, or VS Code's Live Server.

---

## Setup in detail

### 1. Create a Supabase project

1. Go to <https://supabase.com/dashboard> and sign in.
2. **New project** → give it a name, set a database password, pick a region
   close to the salon.
3. Wait ~2 minutes for it to provision.

### 2. Create the tables

1. In your project, open **SQL Editor** in the left sidebar.
2. Click **New query**.
3. Paste the entire contents of [`schema.sql`](./schema.sql) and hit **Run**.

That creates `salons` and `waitlists`, adds the indexes, **turns on Realtime**,
and applies permissive dev-mode security policies so the app works right away.

> Realtime is the step people miss. If your screens only refresh every 30
> seconds instead of instantly, this is why — re-run `schema.sql`.

### 3. Find your two keys

Both live in your project's settings:

**`SUPABASE_URL`**
> Dashboard → your project → **Settings** (gear icon) → **Data API** → **Project URL**

Looks like `https://abcdefghijklmnop.supabase.co`

**`SUPABASE_KEY`**
> Dashboard → your project → **Settings** → **API Keys** → **Publishable key**

Looks like `sb_publishable_xxxxxxxxxxxxx` (older projects label this
**anon public** and it looks like a long `eyJhbGci...` JWT — either is fine).

Direct link, replacing `<your-project-ref>`:
`https://supabase.com/dashboard/project/<your-project-ref>/settings/api-keys`

### 4. Fill in `.env`

```bash
cp .env.example .env
```

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

Browsers can't read `.env` files, so this script copies the values into
`config.js`, which the HTML pages load with a `<script>` tag. Re-run it any time
you change `.env`.

It also validates what you pasted — it will refuse to write a secret key into a
browser file.

**No Node installed?** Skip the script:

```bash
cp config.example.js config.js
# then edit config.js by hand
```

---

## About the keys

| Key | Name in dashboard | Safe in the browser? |
|---|---|---|
| Publishable | **Publishable key** / anon public | **Yes** — it's designed for this |
| Secret | **Secret key** / service_role | **Never.** Bypasses all security |

The publishable key is *meant* to ship in frontend code. What actually protects
your data is Row Level Security, configured in `schema.sql`. The secret key
ignores RLS entirely — if it reaches a browser, anyone can read and delete
everything. It has no place in this project.

Both `.env` and `config.js` are in `.gitignore`. Keep it that way.

---

## Settings you can tune

In `.env`, then re-run `npm run config`:

| Variable | Default | Effect |
|---|---|---|
| `SALON_ID` | `1` | Which `salons` row this install serves |
| `MINUTES_PER_CLIENT` | `15` | Average haircut length |
| `ACTIVE_CHAIRS` | `1` | Chairs running now |

The wait estimate is `ceil(people_waiting / ACTIVE_CHAIRS) × MINUTES_PER_CLIENT`.
Six people across three chairs is two rounds, so 30 minutes — not 90.

---

## Project layout

```
ICON/
├── index.html           Customer check-in page
├── admin.html           Stylist console
├── tv.html              Lobby display board
├── icon.js              Shared client, escaping, queue query, realtime
├── config.example.js    Manual config template
├── config.js            GENERATED — gitignored
├── .env.example         Env template with key-finding instructions
├── .env                 Your keys — gitignored
├── schema.sql           Tables, indexes, realtime, RLS policies
├── scripts/
│   └── build-config.js  .env → config.js
└── package.json
```

`icon.js` holds everything the three pages share: the Supabase client, HTML
escaping, phone validation, the wait-time formula, the open-queue query, and the
realtime subscription with its polling fallback. Edit behaviour there once
instead of in three places.

---

## How the queue works

Rows in `waitlists` move through four states:

```
waiting ──[Call Client]──> in_chair ──[Finish]──> done
   │                           │
   └────────[Remove]───────────┴──────────────> cancelled
```

Nothing is ever hard-deleted — "Remove" and "Purge Queue" set `cancelled`, so you
keep a full history for reporting. Only `waiting` and `in_chair` rows from the
last 12 hours appear on screen.

A unique index allows one active check-in per phone number per salon, so the same
customer can't take two slots.

---

## Going to production

The dev-mode policies in `schema.sql` let anyone with your publishable key modify
the queue. That's fine on localhost; it is not fine in a real salon, where
`admin.html` is a public URL with a **Purge Queue** button on it.

Before you go live:

1. **Add staff login.** Section 5 of `schema.sql` has the production RLS policies
   and the `staff` table, commented out with step-by-step instructions. Enable
   Email auth, turn off public sign-ups, create users manually, then swap the
   `dev open *` policies for the staff-scoped ones.
2. **Gate `admin.html`.** Add a session check at the top of its script:
   ```js
   const { data } = await ICON.db.auth.getSession();
   if (!data.session) location.href = './login.html';
   ```
3. **Keep phone numbers off the TV.** `tv.html` already selects only
   `customer_name` and `status`. Note that Supabase Realtime filters *rows* by
   RLS but not *columns* — anyone who can select a row receives every column over
   the websocket. If that's a concern, move `phone_number` to a staff-only table.
4. **Rotate any key you've already committed.** Settings → API Keys → rotate.

---

## Deploying

It's a static folder — run `npm run config` first, then upload everything except
`.env`, `node_modules` and `schema.sql`.

```bash
npx vercel --prod          # or:
npx netlify deploy --prod
```

For the lobby TV, point a browser at `tv.html` in fullscreen (`F11`) with
auto-sleep disabled. A Raspberry Pi in kiosk mode works well.

---

## Troubleshooting

| What you see | Cause | Fix |
|---|---|---|
| Red bar: "config.js is missing or empty" | No `config.js` | `cp .env.example .env`, fill it in, `npm run config` |
| Red bar: "supabase-js did not load" | No internet, or CDN blocked | Check connection; the three CDN `<script>` tags in `<head>` must load |
| Red bar: "still contains placeholder values" | `config.js` wasn't edited | Put real values in `.env` and re-run `npm run config` |
| Page loads, queue empty, console shows a 401/42501 | RLS policies missing | Re-run `schema.sql` |
| Updates take 30s instead of being instant | Realtime not enabled | Re-run `schema.sql` (section 3), or Database → Replication → add `waitlists` |
| "relation public.waitlists does not exist" | Schema never ran | Run `schema.sql` in the SQL Editor |
| Check-in says "already on the waitlist" | Unique index working as intended | Finish or remove that customer first |
| Everything blank and unstyled | Opened via `file://` | Serve over HTTP — `npm start` |

Every error also prints to the browser console with an `[ICON]` prefix.

---

## What changed from the first version

The original wouldn't start. Fixed:

- CDN `<script>` tags pointed at bare domains (`https://jsdelivr.net`,
  `https://tailwindcss.com`, `https://cloudflare.com`) which return HTML, not
  JavaScript — so `supabase` was undefined and Tailwind and Font Awesome never
  loaded. Now pinned, real URLs.
- `config.js` was referenced but didn't exist. Now generated from `.env`, with a
  clear on-screen error if it's missing.
- `index.html` was truncated mid-function, and `openBookingSlider()`,
  `closeBookingSlider()`, `resetForm()` and the form submit handler were never
  defined. All implemented.
- `admin.html` had `\${...}` inside template literals, printing `${entry.id}`
  literally and breaking the **Call Client** button. Rewritten with event
  delegation instead of inline `onclick`.
- Customer names and notes went into `innerHTML` unescaped — a stored XSS hole on
  the admin console and the lobby TV. Everything now goes through `ICON.esc()`.
- `tv.html` fetched phone numbers and clip notes to a public screen, and shadowed
  the Supabase `client` variable in a `forEach`. Both fixed.
- Queries were unfiltered `select('*')` over all history. Now scoped by salon,
  status and a 12-hour window, with a supporting index.
- Hard `delete()` on "Remove" and "Purge" destroyed history. Both now set status.
- No error handling anywhere — failures were silent. Every call is checked and
  surfaced in the UI.
- Wait time ignored how many stylists were working. Now divides by `ACTIVE_CHAIRS`.
- No phone validation, no duplicate prevention, no loading states, no reconnect
  handling. All added.

---

## License

MIT
