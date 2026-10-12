/* ============================================================
   ICON — Shared runtime
   Loaded by index.html, admin.html and tv.html AFTER config.js
   and AFTER the supabase-js UMD bundle.
   ============================================================ */

(function () {
  'use strict';

  /* ---------- 1. Guard: dependencies present? --------------- */

  function fatal(message) {
    document.addEventListener('DOMContentLoaded', function () {
      var bar = document.createElement('div');
      bar.style.cssText =
        'position:fixed;left:0;right:0;bottom:0;z-index:9999;padding:14px 18px;' +
        'font:600 13px/1.5 ui-sans-serif,system-ui,sans-serif;color:#fff;background:#e11d48;';
      bar.textContent = 'ICON setup error — ' + message;
      document.body.appendChild(bar);
    });
    console.error('[ICON] ' + message);
  }

  if (typeof window.supabase === 'undefined' || !window.supabase.createClient) {
    fatal('supabase-js did not load. Check your internet connection and the <script> tag in <head>.');
    return;
  }

  var cfg = window.ICON_CONFIG;
  if (!cfg || !cfg.SUPABASE_URL || !cfg.SUPABASE_KEY) {
    fatal('config.js is missing or empty. Copy config.example.js to config.js and fill in your keys (see README).');
    return;
  }
  if (/YOUR_PROJECT|YOUR_KEY|PASTE_/.test(cfg.SUPABASE_URL + cfg.SUPABASE_KEY)) {
    fatal('config.js still contains placeholder values. Add your real Supabase URL and publishable key.');
    return;
  }

  /* ---------- 2. Supabase client ----------------------------- */

  var db = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_KEY, {
    realtime: { params: { eventsPerSecond: 5 } }
  });

  /* ---------- 3. Settings ------------------------------------ */

  var SALON_ID = cfg.SALON_ID || 1;
  var MINUTES_PER_CLIENT = cfg.MINUTES_PER_CLIENT || 15;
  var ACTIVE_CHAIRS = cfg.ACTIVE_CHAIRS || 1;
  var TABLE = 'waitlists';

  /* ---------- 4. XSS-safe helpers ---------------------------- */

  // Escapes a value for safe insertion into an HTML template literal.
  function esc(value) {
    if (value === null || value === undefined) return '';
    return String(value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Normalises a phone number to digits (keeps a leading +).
  function normalisePhone(raw) {
    var trimmed = String(raw || '').trim();
    var plus = trimmed.charAt(0) === '+' ? '+' : '';
    return plus + trimmed.replace(/[^0-9]/g, '');
  }

  function isValidPhone(raw) {
    var n = normalisePhone(raw).replace('+', '');
    return n.length >= 10 && n.length <= 15;
  }

  /* ---------- 5. Wait-time maths ----------------------------- */

  function estimateWaitMinutes(waitingCount) {
    var chairs = Math.max(1, ACTIVE_CHAIRS);
    return Math.ceil(waitingCount / chairs) * MINUTES_PER_CLIENT;
  }

  /* ---------- 6. Data access -------------------------------- */

  // Only today's open rows, only the columns each page needs.
  function openQueue(columns) {
    var since = new Date(Date.now() - 12 * 60 * 60 * 1000).toISOString();
    return db
      .from(TABLE)
      .select(columns || 'id,customer_name,clip_notes,status,join_time')
      .eq('salon_id', SALON_ID)
      .in('status', ['waiting', 'in_chair'])
      .gte('join_time', since)
      .order('join_time', { ascending: true });
  }

  /* ---------- 7. Realtime ----------------------------------- */

  // Subscribes to every change on the waitlist and calls handler().
  // Also polls as a safety net in case the websocket drops.
  function subscribeQueue(channelName, handler) {
    handler();

    db.channel(channelName)
      .on('postgres_changes', { event: '*', schema: 'public', table: TABLE }, handler)
      .subscribe(function (status) {
        console.log('[ICON] realtime ' + channelName + ': ' + status);
      });

    // Fallback refresh every 30s + whenever the tab regains focus.
    setInterval(handler, 30000);
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden) handler();
    });
  }

  /* ---------- 8. Export ------------------------------------- */

  window.ICON = {
    db: db,
    TABLE: TABLE,
    SALON_ID: SALON_ID,
    MINUTES_PER_CLIENT: MINUTES_PER_CLIENT,
    ACTIVE_CHAIRS: ACTIVE_CHAIRS,
    esc: esc,
    normalisePhone: normalisePhone,
    isValidPhone: isValidPhone,
    estimateWaitMinutes: estimateWaitMinutes,
    openQueue: openQueue,
    subscribeQueue: subscribeQueue
  };
})();
