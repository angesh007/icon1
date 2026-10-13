/* ============================================================
   ICON — shared runtime  (v3)
   Loaded by every page AFTER config.js and the supabase-js bundle.

   window.ICON:
     db, esc, fmtTime, fmtDate, fmtDay, fmtRelative, fmtPhone, fmtMoney
     shop.{resolve, current, slugFromUrl, customerUrl}
     queue.{open, subscribe, estimate, etaFor, positionOf, timeSlots}
     book.{slots, calendar, create, status, cancel, mine, forget}
     ticket.{mine, forget}
     auth.{login, logout, restore, require, token}
     admin.{queue, register, setStatus, purge, appointments,
            appointmentCounts, setAppointmentStatus, book,
            services, serviceSave, serviceRetire,
            staff, staffSave, staffRetire,
            hours, hoursSave, closures, closureSet,
            shop, shopSave, changePassword}
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
        'font:600 13px/1.5 ui-sans-serif,system-ui,sans-serif;color:#fff;background:#D8232A;';
      bar.textContent = 'ICON setup error — ' + message;
      document.body.appendChild(bar);
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', paint);
    else paint();
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

  /* ---------- Client ------------------------------------------- */

  var db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
    realtime: { params: { eventsPerSecond: 5 } },
    auth: { persistSession: false }
  });

  var TABLE = 'waitlists';
  var TICKET_KEY = 'icon.ticket.v3';
  var BOOKING_KEY = 'icon.booking.v3';
  var SESSION_KEY = 'icon.staff.v3';

  /* ---------- Escaping + formatting ---------------------------- */

  function esc(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function toDate(value) {
    if (value instanceof Date) return value;
    var d = new Date(value);
    return isNaN(d) ? null : d;
  }

  function fmtTime(value) {
    var d = toDate(value);
    if (!d) return '';
    var h = d.getHours(), m = d.getMinutes();
    var suffix = h >= 12 ? 'pm' : 'am';
    h = h % 12; if (h === 0) h = 12;
    return h + ':' + (m < 10 ? '0' + m : m) + ' ' + suffix;
  }

  var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var DAYS_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  // "Tue 14 Oct", or "Today" / "Tomorrow"
  function fmtDate(value, opts) {
    var d = toDate(value);
    if (!d) return '';
    if (!(opts && opts.absolute)) {
      var today = new Date(); today.setHours(0, 0, 0, 0);
      var that = new Date(d); that.setHours(0, 0, 0, 0);
      var diff = Math.round((that - today) / 86400000);
      if (diff === 0) return 'Today';
      if (diff === 1) return 'Tomorrow';
    }
    return DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()];
  }

  function fmtDay(weekday, long) { return (long ? DAYS_LONG : DAYS)[weekday]; }

  function fmtRelative(value) {
    var d = toDate(value);
    if (!d) return '';
    var mins = Math.round((Date.now() - d.getTime()) / 60000);
    if (mins < 1) return 'just now';
    if (mins === 1) return '1 min ago';
    if (mins < 60) return mins + ' min ago';
    var h = Math.floor(mins / 60);
    return h === 1 ? '1 hr ago' : h + ' hrs ago';
  }

  function fmtPhone(raw) {
    var d = String(raw || '').replace(/[^0-9]/g, '');
    var intl = String(raw || '').trim().charAt(0) === '+' || d.length > 10;
    if (d.length === 11 && d.charAt(0) === '1') d = d.slice(1);
    if (d.length === 10) return '(' + d.slice(0, 3) + ') ' + d.slice(3, 6) + '-' + d.slice(6);
    if (intl && d.length > 10) {
      return '+' + d.slice(0, d.length - 10) + ' ' + d.slice(-10, -5) + ' ' + d.slice(-5);
    }
    return String(raw || '');
  }

  // Prices are stored in minor units (paise / cents).
  function fmtMoney(minor, currency) {
    var sym = currency || (shop.current && shop.current.currency) || '₹';
    var major = (Number(minor) || 0) / 100;
    var str = major % 1 === 0 ? String(major) : major.toFixed(2);
    // Indian grouping for the rupee, plain thousands otherwise.
    if (sym === '₹') {
      var parts = str.split('.');
      var n = parts[0];
      if (n.length > 3) {
        var last3 = n.slice(-3);
        var rest = n.slice(0, -3).replace(/\B(?=(\d{2})+(?!\d))/g, ',');
        n = rest + ',' + last3;
      }
      str = n + (parts[1] ? '.' + parts[1] : '');
    } else {
      str = str.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    }
    return sym + str;
  }

  function padTicket(n) {
    if (n === null || n === undefined) return '--';
    return n < 10 ? '0' + n : String(n);
  }

  // YYYY-MM-DD in the viewer's own timezone (never toISOString, which is UTC).
  function dateKey(value) {
    var d = toDate(value) || new Date();
    var m = d.getMonth() + 1, day = d.getDate();
    return d.getFullYear() + '-' + (m < 10 ? '0' + m : m) + '-' + (day < 10 ? '0' + day : day);
  }

  function addDays(value, n) {
    var d = new Date(toDate(value) || new Date());
    d.setDate(d.getDate() + n);
    return d;
  }

  /* ---------- Phone ------------------------------------------- */

  function normalisePhone(raw) {
    var trimmed = String(raw || '').trim();
    if (!trimmed) return null;
    var plus = trimmed.charAt(0) === '+' ? '+' : '';
    var digits = plus + trimmed.replace(/[^0-9]/g, '');
    return digits === '+' ? null : digits;
  }

  function isValidPhone(raw) {
    var n = normalisePhone(raw);
    if (!n) return false;
    var digits = n.replace('+', '');
    return digits.length >= 10 && digits.length <= 15;
  }

  /* ---------- Storage ----------------------------------------- */

  function store(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, JSON.stringify(value));
    } catch (e) { /* private mode — not fatal */ }
  }

  function recall(key) {
    try {
      var raw = localStorage.getItem(key);
      return raw ? JSON.parse(raw) : null;
    } catch (e) { return null; }
  }

  function cleanError(error) {
    var msg = (error && (error.message || error.hint)) || 'Something went wrong';
    return String(msg).replace(/^(ERROR|error):\s*/i, '');
  }

  /* ============================================================
     Shop resolution
     ============================================================ */

  var shop = {
    current: null,

    slugFromUrl: function () {
      var q = new URLSearchParams(location.search);
      return q.get('shop') || q.get('s') || cfg.SHOP_SLUG || null;
    },

    // Public URL a customer should land on, used by the QR code.
    customerUrl: function (slug) {
      var s = slug || (shop.current && shop.current.slug);
      var base = location.origin + location.pathname.replace(/[^/]*$/, '') + 'index.html';
      return base + (s ? '?shop=' + encodeURIComponent(s) : '');
    },

    // { ok:true, shop } | { ok:false, error } | { ok:false, browse:true }
    //
    // `browse` means no shop was named and there is more than one to choose
    // from, so the caller should show the directory instead of guessing.
    resolve: async function (slug, opts) {
      var want = slug || shop.slugFromUrl();

      if (!want) {
        var list = await db.rpc('shop_list', { p_category: null });
        var shops = (!list.error && Array.isArray(list.data)) ? list.data : [];

        if (shops.length === 1) {
          want = shops[0].slug;               // only one shop: just open it
        } else if (shops.length > 1 && !(opts && opts.fallback)) {
          return { ok: false, browse: true, shops: shops };
        } else {
          want = String(cfg.SALON_ID || 1);   // last resort
        }
      }

      var res = await db.rpc('shop_by_slug', { p_slug: String(want) });
      if (res.error) {
        console.error('[ICON] shop_by_slug failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }

      shop.current = res.data;
      return { ok: true, shop: res.data };
    },

    list: async function (category) {
      var res = await db.rpc('shop_list', { p_category: category || null });
      return res.error ? { ok: false, error: cleanError(res.error) } : { ok: true, data: res.data || [] };
    },

    categories: async function () {
      var res = await db.rpc('category_list');
      return res.error ? { ok: false, error: cleanError(res.error) } : { ok: true, data: res.data || [] };
    },

    // Services grouped by audience, in menu order.
    servicesFor: function (audience) {
      var all = (shop.current && shop.current.services) || [];
      if (!audience) return all;
      return all.filter(function (s) { return s.audience === audience || s.audience === 'unisex'; });
    },

    audiences: function () {
      var seen = {};
      ((shop.current && shop.current.services) || []).forEach(function (s) {
        if (s.audience !== 'unisex') seen[s.audience] = true;
      });
      return ['men', 'women', 'kids'].filter(function (a) { return seen[a]; });
    },

    hoursFor: function (weekday) {
      return (((shop.current && shop.current.hours) || [])
        .filter(function (h) { return h.weekday === weekday; })[0]) || null;
    }
  };

  /* ============================================================
     Live queue
     ============================================================ */

  var queue = {
    salonId: function () {
      return (shop.current && shop.current.id) || cfg.SALON_ID || 1;
    },

    chairs: function () {
      var n = (shop.current && shop.current.active_chairs) || cfg.ACTIVE_CHAIRS || 1;
      return Math.max(1, n);
    },

    serviceMinutes: function () {
      return (shop.current && shop.current.avg_service_minutes) || cfg.MINUTES_PER_CLIENT || 15;
    },

    open: function (columns) {
      return db
        .from(TABLE)
        .select(columns || 'id,ticket_no,customer_name,status,join_time,preferred_time,service_id')
        .eq('salon_id', queue.salonId())
        .in('status', ['waiting', 'in_chair'])
        .order('join_time', { ascending: true });
    },

    minutesForPosition: function (position) {
      return Math.ceil(position / queue.chairs()) * queue.serviceMinutes();
    },

    estimate: function (waitingCount) { return queue.minutesForPosition(waitingCount); },

    etaFor: function (position) {
      return new Date(Date.now() + queue.minutesForPosition(position) * 60000);
    },

    positionOf: function (rows, entryId) {
      var waiting = rows.filter(function (r) { return r.status === 'waiting'; });
      for (var i = 0; i < waiting.length; i++) {
        if (Number(waiting[i].id) === Number(entryId)) return i + 1;
      }
      return 0;
    },

    // Next few half-hour marks after the current wait — "come back at".
    timeSlots: function (waitingCount, count) {
      var slots = [];
      var d = new Date(Date.now() + queue.estimate(waitingCount) * 60000);
      d.setSeconds(0, 0);
      d.setMinutes(d.getMinutes() <= 30 ? 30 : 60);
      for (var i = 0; i < (count || 4); i++) {
        slots.push(new Date(d.getTime() + i * 30 * 60000));
      }
      return slots;
    },

    subscribe: function (channelName, handler) {
      handler();
      db.channel(channelName)
        .on('postgres_changes', { event: '*', schema: 'public', table: TABLE }, handler)
        .subscribe(function (status) {
          console.log('[ICON] realtime ' + channelName + ': ' + status);
        });
      setInterval(handler, 30000);
      document.addEventListener('visibilitychange', function () {
        if (!document.hidden) handler();
      });
    },

    // Join the walk-in line. Phone may be null.
    join: async function (opts) {
      var res = await db.rpc('check_in', {
        p_salon: queue.salonId(),
        p_name: opts.name,
        p_phone: normalisePhone(opts.phone),
        p_notes: opts.notes || null,
        p_preferred_time: opts.preferredTime ? new Date(opts.preferredTime).toISOString() : null,
        p_service_id: opts.serviceId || null,
        p_staff_id: opts.staffId || null
      });

      if (res.error) {
        console.error('[ICON] check_in failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }

      var t = {
        shop_id: queue.salonId(),
        shop_slug: shop.current && shop.current.slug,
        entry_id: res.data.entry_id,
        ticket_no: res.data.ticket_no,
        name: opts.name,
        notes: opts.notes || null,
        service_id: opts.serviceId || null,
        service_name: opts.serviceName || null,
        preferred_time: opts.preferredTime || null,
        issued_at: new Date().toISOString()
      };
      store(TICKET_KEY, t);
      return { ok: true, ticket: t };
    }
  };

  var ticket = {
    mine: function () {
      var t = recall(TICKET_KEY);
      if (!t) return null;
      if (new Date(t.issued_at).toDateString() !== new Date().toDateString()) {
        store(TICKET_KEY, null);
        return null;
      }
      // A ticket from another shop isn't this shop's ticket.
      if (shop.current && t.shop_id && Number(t.shop_id) !== Number(shop.current.id)) return null;
      return t;
    },
    forget: function () { store(TICKET_KEY, null); }
  };

  /* ============================================================
     Appointments
     ============================================================ */

  var book = {
    // Free start times for one day.
    slots: async function (dateStr, serviceId, staffId) {
      var res = await db.rpc('available_slots', {
        p_salon: queue.salonId(),
        p_date: dateStr,
        p_service_id: serviceId || null,
        p_staff_id: staffId || null
      });
      if (res.error) {
        console.error('[ICON] available_slots failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }
      return { ok: true, data: res.data || [] };
    },

    // Free-slot count per day, for the customer calendar.
    calendar: async function (fromStr, days, serviceId) {
      var res = await db.rpc('availability_calendar', {
        p_salon: queue.salonId(),
        p_from: fromStr,
        p_days: days || 14,
        p_service_id: serviceId || null
      });
      if (res.error) {
        console.error('[ICON] availability_calendar failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }
      return { ok: true, data: res.data || [] };
    },

    create: async function (opts) {
      var res = await db.rpc('book_appointment', {
        p_salon: queue.salonId(),
        p_service_id: opts.serviceId,
        p_starts_at: new Date(opts.startsAt).toISOString(),
        p_name: opts.name,
        p_phone: normalisePhone(opts.phone),
        p_notes: opts.notes || null,
        p_staff_id: opts.staffId || null
      });

      if (res.error) {
        console.error('[ICON] book_appointment failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }

      var b = {
        shop_id: queue.salonId(),
        shop_slug: shop.current && shop.current.slug,
        id: res.data.id,
        lookup_code: res.data.lookup_code,
        starts_at: res.data.starts_at,
        ends_at: res.data.ends_at,
        service: res.data.service,
        price_minor: res.data.price_minor,
        name: opts.name
      };
      store(BOOKING_KEY, b);
      return { ok: true, booking: b };
    },

    status: async function (code) {
      var res = await db.rpc('appointment_status', { p_code: code });
      if (res.error) return { ok: false, error: cleanError(res.error) };
      return { ok: true, data: res.data };
    },

    cancel: async function (code) {
      var res = await db.rpc('cancel_appointment', { p_code: code });
      if (res.error) return { ok: false, error: cleanError(res.error) };
      store(BOOKING_KEY, null);
      return { ok: true };
    },

    mine: function () {
      var b = recall(BOOKING_KEY);
      if (!b) return null;
      // Drop it once the slot is well past.
      if (new Date(b.ends_at).getTime() < Date.now() - 2 * 3600000) {
        store(BOOKING_KEY, null);
        return null;
      }
      if (shop.current && b.shop_id && Number(b.shop_id) !== Number(shop.current.id)) return null;
      return b;
    },

    forget: function () { store(BOOKING_KEY, null); }
  };

  /* ============================================================
     Staff auth
     ============================================================ */

  var auth = {
    current: null,

    login: async function (adminId, password) {
      var res = await db.rpc('admin_login', { p_admin_id: adminId, p_password: password });
      if (res.error) {
        console.error('[ICON] admin_login failed:', res.error);
        return { ok: false, error: cleanError(res.error) };
      }

      // admin_login RETURNS failures so the lockout counter can commit.
      var out = res.data || {};
      if (!out.ok) {
        return {
          ok: false,
          error: out.error || 'Incorrect staff ID or password',
          locked: !!out.locked
        };
      }

      var staff = {
        token: out.token, admin_id: out.admin_id, display_name: out.display_name,
        role: out.role, salon_id: out.salon_id, salon_slug: out.salon_slug,
        expires_at: out.expires_at
      };
      store(SESSION_KEY, staff);
      auth.current = staff;
      return { ok: true, staff: staff };
    },

    logout: async function () {
      var staff = auth.current || recall(SESSION_KEY);
      if (staff && staff.token) {
        try { await db.rpc('admin_logout', { p_token: staff.token }); } catch (e) { /* best effort */ }
      }
      store(SESSION_KEY, null);
      auth.current = null;
    },

    restore: async function () {
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
      staff.salon_slug = res.data.salon_slug;
      staff.salon_name = res.data.salon_name;
      store(SESSION_KEY, staff);
      auth.current = staff;
      return staff;
    },

    require: async function (loginUrl) {
      var staff = await auth.restore();
      if (!staff) {
        var here = location.pathname.split('/').pop() || 'admin.html';
        location.replace((loginUrl || './login.html') + '?next=' + encodeURIComponent(here));
        return null;
      }
      return staff;
    },

    token: function () {
      var staff = auth.current || recall(SESSION_KEY);
      return staff ? staff.token : null;
    },

    isManager: function () {
      var s = auth.current || recall(SESSION_KEY);
      return !!s && (s.role === 'manager' || s.role === 'owner');
    }
  };

  /* ---------- Staff RPC helper -------------------------------- */

  async function rpcAsStaff(fn, args) {
    var token = auth.token();
    if (!token) return { ok: false, error: 'Not signed in', expired: true };

    var res = await db.rpc(fn, Object.assign({ p_token: token }, args || {}));

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
    /* the line */
    queue: function () { return rpcAsStaff('admin_queue'); },
    register: function (o) {
      return rpcAsStaff('admin_register_walkin', {
        p_name: o.name, p_phone: normalisePhone(o.phone), p_notes: o.notes || null,
        p_preferred_time: o.preferredTime ? new Date(o.preferredTime).toISOString() : null,
        p_service_id: o.serviceId || null, p_staff_id: o.staffId || null
      });
    },
    setStatus: function (id, status) {
      return rpcAsStaff('admin_set_status', { p_entry_id: id, p_status: status });
    },
    purge: function () { return rpcAsStaff('admin_purge'); },

    /* the calendar */
    appointments: function (fromStr, toStr) {
      return rpcAsStaff('admin_appointments', { p_from: fromStr || null, p_to: toStr || null });
    },
    appointmentCounts: function (fromStr, days) {
      return rpcAsStaff('admin_appointment_counts', { p_from: fromStr, p_days: days || 35 });
    },
    setAppointmentStatus: function (id, status) {
      return rpcAsStaff('admin_set_appointment_status', { p_id: id, p_status: status });
    },
    book: function (o) {
      return rpcAsStaff('admin_book', {
        p_service_id: o.serviceId, p_starts_at: new Date(o.startsAt).toISOString(),
        p_name: o.name, p_phone: normalisePhone(o.phone), p_notes: o.notes || null,
        p_staff_id: o.staffId || null
      });
    },

    /* services */
    services: function () { return rpcAsStaff('admin_services'); },
    serviceSave: function (s) {
      return rpcAsStaff('admin_service_save', {
        p_id: s.id || null, p_name: s.name, p_audience: s.audience,
        p_category: s.category, p_duration: s.duration,
        p_price_minor: s.priceMinor, p_is_active: s.isActive !== false,
        p_sort: s.sort || 0
      });
    },
    serviceRetire: function (id) { return rpcAsStaff('admin_service_retire', { p_id: id }); },

    /* team */
    staff: function () { return rpcAsStaff('admin_staff'); },
    staffSave: function (s) {
      return rpcAsStaff('admin_staff_save', {
        p_id: s.id || null, p_name: s.name, p_title: s.title || null,
        p_is_active: s.isActive !== false, p_sort: s.sort || 0
      });
    },
    staffRetire: function (id) { return rpcAsStaff('admin_staff_retire', { p_id: id }); },

    /* hours */
    hours: function () { return rpcAsStaff('admin_hours'); },
    hoursSave: function (weekday, isOpen, opens, closes) {
      return rpcAsStaff('admin_hours_save', {
        p_weekday: weekday, p_is_open: isOpen, p_opens: opens, p_closes: closes
      });
    },
    closures: function () { return rpcAsStaff('admin_closures'); },
    closureSet: function (dateStr, reason, closed) {
      return rpcAsStaff('admin_closure_set', {
        p_date: dateStr, p_reason: reason || null, p_closed: closed !== false
      });
    },

    /* shop */
    shop: function () { return rpcAsStaff('admin_shop'); },
    shopSave: function (s) {
      return rpcAsStaff('admin_shop_save', {
        p_name: s.name, p_address: s.address || null, p_kind: s.kind || null,
        p_category: s.category || null,
        p_is_open: s.isOpen, p_phone_required: s.phoneRequired,
        p_slot_minutes: s.slotMinutes, p_lead_minutes: s.leadMinutes,
        p_horizon_days: s.horizonDays, p_active_chairs: s.activeChairs,
        p_avg_minutes: s.avgMinutes, p_contact_phone: s.contactPhone || null
      });
    },

    changePassword: function (current, next) {
      return rpcAsStaff('admin_change_password', { p_current: current, p_new: next });
    }
  };

  /* ---------- Export ------------------------------------------ */

  window.ICON = {
    db: db,
    TABLE: TABLE,

    esc: esc,
    fmtTime: fmtTime,
    fmtDate: fmtDate,
    fmtDay: fmtDay,
    fmtRelative: fmtRelative,
    fmtPhone: fmtPhone,
    fmtMoney: fmtMoney,
    padTicket: padTicket,
    dateKey: dateKey,
    addDays: addDays,

    normalisePhone: normalisePhone,
    isValidPhone: isValidPhone,

    shop: shop,
    queue: queue,
    ticket: ticket,
    book: book,
    auth: auth,
    admin: admin,

    cleanError: cleanError,

    // v2 compatibility, so nothing that still calls these breaks.
    SALON_ID: cfg.SALON_ID || 1,
    openQueue: function (c) { return queue.open(c); },
    subscribeQueue: function (n, h) { return queue.subscribe(n, h); },
    estimateWaitMinutes: function (n) { return queue.estimate(n); },
    etaFor: function (p) { return queue.etaFor(p); },
    positionOf: function (r, i) { return queue.positionOf(r, i); },
    timeSlots: function (n, c) { return queue.timeSlots(n, c); }
  };
})();
