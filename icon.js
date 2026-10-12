/* ============================================================
   ICON — shared runtime  (v2)
   Loaded by every page AFTER config.js and the supabase-js bundle.

   Exposes window.ICON with:
     db, SALON_ID, esc, fmtTime, fmtRelative,
     openQueue, subscribeQueue,
     estimate(), checkIn(), ticket helpers,
     auth.{login,logout,session,restore,require}
     admin.{queue,register,setStatus,purge}
   ============================================================ */

(function () {
  'use strict';

  /* ---------- Dependency guard --------------------------------- */

  function fatal(message) {
    function paint() {
      var bar = document.createElement('div');
      bar.setAttribute('role', 'alert');
      bar.style.cssText =
        'position:fixed;left:0;right:0;bottom:0;z-index:9999;padding:14px 18px;' +
        'font:600 13px/1.5 ui-sans-serif,system-ui,sans-serif;color:#fff;' +
        'background:#D8232A;';
      bar.textContent = 'ICON setup error — ' + message;
      document.body.appendChild(bar);
    }
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', paint);
    } else {
      paint();
    }
    console.error('[ICON] ' + message);
  }

  if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
    fatal('supabase-js did not load. Check your connection and the <script> tag in <head>.');
    return;
  }

  var cfg = window.ICON_CONFIG;
  if (!cfg || !cfg.SUPABASE_URL || !cfg.SUPABASE_KEY) {
    fatal('config.js is missing or empty. Locally: copy .env.example to .env and run `npm run config`. ' +
          'On Vercel: set SUPABASE_URL and SUPABASE_KEY, then redeploy.');
    return;
  }
  if (/YOUR_PROJECT|YOUR_KEY|PASTE_/.test(cfg.SUPABASE_URL + cfg.SUPABASE_KEY)) {
    fatal('config.js still has placeholder values. Add your real Supabase URL and publishable key.');
    return;
  }

  /* ---------- Client + settings -------------------------------- */

  var db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
    realtime: { params: { eventsPerSecond: 5 } },
    auth: { persistSession: false }
  });

  var SALON_ID = cfg.SALON_ID || 1;
  var MINUTES_PER_CLIENT = cfg.MINUTES_PER_CLIENT || 15;
  var ACTIVE_CHAIRS = Math.max(1, cfg.ACTIVE_CHAIRS || 1);
  var TABLE = 'waitlists';

  var TICKET_KEY = 'icon.ticket.v2';
  var SESSION_KEY = 'icon.staff.v2';

  /* ---------- Escaping + formatting ---------------------------- */

  function esc(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  // 6:45 pm
  function fmtTime(date) {
    if (!date) return '';
    var d = (date instanceof Date) ? date : new Date(date);
    if (isNaN(d)) return '';
    var h = d.getHours();
    var m = d.getMinutes();
    var suffix = h >= 12 ? 'pm' : 'am';
    h = h % 12; if (h === 0) h = 12;
    return h + ':' + (m < 10 ? '0' + m : m) + ' ' + suffix;
  }

  // "4 min ago"
  function fmtRelative(date) {
    if (!date) return '';
    var mins = Math.round((Date.now() - new Date(date).getTime()) / 60000);
    if (mins < 1) return 'just now';
    if (mins === 1) return '1 min ago';
    if (mins < 60) return mins + ' min ago';
    var h = Math.floor(mins / 60);
    return h === 1 ? '1 hr ago' : h + ' hrs ago';
  }

  function padTicket(n) {
    if (n === null || n === undefined) return '--';
    return n < 10 ? '0' + n : String(n);
  }

  /* ---------- Phone ------------------------------------------- */

  function normalisePhone(raw) {
    var trimmed = String(raw || '').trim();
    var plus = trimmed.charAt(0) === '+' ? '+' : '';
    return plus + trimmed.replace(/[^0-9]/g, '');
  }

  // (404) 555-0101 for a 10-digit number; otherwise grouped sensibly.
  function fmtPhone(raw) {
    var d = String(raw || '').replace(/[^0-9]/g, '');
    var intl = String(raw || '').trim().charAt(0) === '+' || d.length > 10;
    if (d.length === 11 && d.charAt(0) === '1') d = d.slice(1);
    if (d.length === 10) {
      return '(' + d.slice(0, 3) + ') ' + d.slice(3, 6) + '-' + d.slice(6);
    }
    if (intl && d.length > 10) {
      return '+' + d.slice(0, d.length - 10) + ' ' + d.slice(-10, -7) + ' ' +
             d.slice(-7, -4) + ' ' + d.slice(-4);
    }
    return String(raw || '');
  }

  function isValidPhone(raw) {
    var n = normalisePhone(raw).replace('+', '');
    return n.length >= 10 && n.length <= 15;
  }

  /* ---------- Wait maths --------------------------------------- */

  // How many rounds of chairs before this position is reached.
  function minutesForPosition(position) {
    return Math.ceil(position / ACTIVE_CHAIRS) * MINUTES_PER_CLIENT;
  }

  function estimateWaitMinutes(waitingCount) {
    return minutesForPosition(waitingCount);
  }

  function etaFor(position) {
    return new Date(Date.now() + minutesForPosition(position) * 60000);
  }

  // Given the live queue rows, work out where a ticket sits.
  function positionOf(rows, entryId) {
    var waiting = rows.filter(function (r) { return r.status === 'waiting'; });
    for (var i = 0; i < waiting.length; i++) {
      if (Number(waiting[i].id) === Number(entryId)) return i + 1;
    }
    return 0; // not waiting (in chair, or gone)
  }

  /* ---------- Suggested arrival times ------------------------- */

  // Next few half-hour slots after the current estimated wait.
  function timeSlots(waitingCount, count) {
    var slots = [];
    var earliest = Date.now() + estimateWaitMinutes(waitingCount) * 60000;
    var d = new Date(earliest);
    d.setSeconds(0, 0);
    d.setMinutes(d.getMinutes() <= 30 ? 30 : 60);
    for (var i = 0; i < (count || 4); i++) {
      slots.push(new Date(d.getTime() + i * 30 * 60000));
    }
    return slots;
  }

  /* ---------- Safe local storage ------------------------------ */

  function store(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, JSON.stringify(value));
    } catch (e) { /* private mode, blocked storage — not fatal */ }
  }

  function recall(key) {
    try {
      var raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
  }

  /* ---------- Public queue reads ------------------------------ */

  function openQueue(columns) {
    return db
      .from(TABLE)
      .select(columns || 'id,ticket_no,customer_name,status,join_time,preferred_time')
      .eq('salon_id', SALON_ID)
      .in('status', ['waiting', 'in_chair'])
      .order('join_time', { ascending: true });
  }

  function subscribeQueue(channelName, handler) {
    handler();

    db.channel(channelName)
      .on('postgres_changes', { event: '*', schema: 'public', table: TABLE }, handler)
      .subscribe(function (status) {
        console.log('[ICON] realtime ' + channelName + ': ' + status);
      });

    // Safety net if the socket drops, plus a refresh on refocus.
    setInterval(handler, 30000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) handler();
    });
  }

  /* ---------- Customer check-in ------------------------------- */

  // Returns { ok:true, entry_id, ticket_no } or { ok:false, error }
  async function checkIn(name, phone, notes, preferredTime) {
    var res = await db.rpc('check_in', {
      p_salon: SALON_ID,
      p_name: name,
      p_phone: normalisePhone(phone),
      p_notes: notes || null,
      p_preferred_time: preferredTime ? new Date(preferredTime).toISOString() : null
    });

    if (res.error) {
      console.error('[ICON] check_in failed:', res.error);
      return { ok: false, error: cleanError(res.error) };
    }

    var ticket = {
      entry_id: res.data.entry_id,
      ticket_no: res.data.ticket_no,
      name: name,
      notes: notes || null,
      preferred_time: preferredTime || null,
      issued_at: new Date().toISOString()
    };
    store(TICKET_KEY, ticket);
    return { ok: true, ticket: ticket };
  }

  function myTicket() {
    var t = recall(TICKET_KEY);
    if (!t) return null;
    // Tickets are per-day; drop anything from a previous day.
    if (new Date(t.issued_at).toDateString() !== new Date().toDateString()) {
      store(TICKET_KEY, null);
      return null;
    }
    return t;
  }

  function forgetTicket() { store(TICKET_KEY, null); }

  /* ---------- Staff auth -------------------------------------- */

  // Postgres sends back a useful message; strip the plumbing.
  function cleanError(error) {
    var msg = (error && (error.message || error.hint)) || 'Something went wrong';
    return String(msg).replace(/^(ERROR|error):\s*/i, '');
  }

  var auth = {
    current: null,

    // { ok:true, staff } | { ok:false, error }
    async login(adminId, password) {
      var res = await db.rpc('admin_login', {
        p_admin_id: adminId,
        p_password: password
      });

      if (res.error) {
        console.error('[ICON] admin_login failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }

      // admin_login RETURNS failures rather than raising them, so the
      // lockout counter can commit. Always check ok.
      var out = res.data || {};
      if (!out.ok) {
        return { ok: false, error: out.error || 'Incorrect staff ID or password', locked: !!out.locked };
      }

      var staff = {
        token: out.token,
        admin_id: out.admin_id,
        display_name: out.display_name,
        role: out.role,
        salon_id: out.salon_id,
        expires_at: out.expires_at
      };
      store(SESSION_KEY, staff);
      auth.current = staff;
      return { ok: true, staff: staff };
    },

    async logout() {
      var staff = auth.current || recall(SESSION_KEY);
      if (staff && staff.token) {
        try { await db.rpc('admin_logout', { p_token: staff.token }); } catch (e) { /* best effort */ }
      }
      store(SESSION_KEY, null);
      auth.current = null;
    },

    // Revalidates the stored token against the server.
    async restore() {
      var staff = recall(SESSION_KEY);
      if (!staff || !staff.token) return null;

      var res = await db.rpc('admin_session', { p_token: staff.token });
      if (res.error || !res.data) {
        store(SESSION_KEY, null);
        auth.current = null;
        return null;
      }

      staff.display_name = res.data.display_name;
      staff.role = res.data.role;
      staff.salon_id = res.data.salon_id;
      store(SESSION_KEY, staff);
      auth.current = staff;
      return staff;
    },

    // Redirects to the login page when there is no valid session.
    async require(loginUrl) {
      var staff = await auth.restore();
      if (!staff) {
        var back = encodeURIComponent(location.pathname.split('/').pop() || 'admin.html');
        location.replace((loginUrl || './login.html') + '?next=' + back);
        return null;
      }
      return staff;
    },

    token() {
      var staff = auth.current || recall(SESSION_KEY);
      return staff ? staff.token : null;
    }
  };

  /* ---------- Staff actions ----------------------------------- */

  async function rpcAsStaff(fn, args) {
    var token = auth.token();
    if (!token) return { ok: false, error: 'Not signed in', expired: true };

    var payload = Object.assign({ p_token: token }, args || {});
    var res = await db.rpc(fn, payload);

    if (res.error) {
      var msg = cleanError(res.error);
      var expired = /session expired|not signed in/i.test(msg);
      if (expired) { store(SESSION_KEY, null); auth.current = null; }
      console.error('[ICON] ' + fn + ' failed:', res.error);
      return { ok: false, error: msg, expired: expired };
    }
    return { ok: true, data: res.data };
  }

  var admin = {
    queue: function () { return rpcAsStaff('admin_queue'); },

    register: function (name, phone, notes, preferredTime) {
      return rpcAsStaff('admin_register_walkin', {
        p_name: name,
        p_phone: normalisePhone(phone),
        p_notes: notes || null,
        p_preferred_time: preferredTime ? new Date(preferredTime).toISOString() : null
      });
    },

    setStatus: function (entryId, status) {
      return rpcAsStaff('admin_set_status', { p_entry_id: entryId, p_status: status });
    },

    purge: function () { return rpcAsStaff('admin_purge'); },

    changePassword: function (current, next) {
      return rpcAsStaff('admin_change_password', { p_current: current, p_new: next });
    }
  };

  /* ---------- Export ------------------------------------------ */

  window.ICON = {
    db: db,
    TABLE: TABLE,
    SALON_ID: SALON_ID,
    MINUTES_PER_CLIENT: MINUTES_PER_CLIENT,
    ACTIVE_CHAIRS: ACTIVE_CHAIRS,

    esc: esc,
    fmtTime: fmtTime,
    fmtRelative: fmtRelative,
    padTicket: padTicket,

    normalisePhone: normalisePhone,
    isValidPhone: isValidPhone,
    fmtPhone: fmtPhone,

    estimateWaitMinutes: estimateWaitMinutes,
    minutesForPosition: minutesForPosition,
    etaFor: etaFor,
    positionOf: positionOf,
    timeSlots: timeSlots,

    openQueue: openQueue,
    subscribeQueue: subscribeQueue,

    checkIn: checkIn,
    myTicket: myTicket,
    forgetTicket: forgetTicket,

    auth: auth,
    admin: admin,
    cleanError: cleanError
  };
})();
