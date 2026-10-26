/* ============================================================
   ICON — shared interface layer (ui.js)
   Loaded by the customer page and the staff pages, after the page
   markup and before the page's own script. No dependencies.

   window.MS:
     refresh(root, { instant })   wire reveals, parallax and magnetic
                                  buttons in freshly rendered markup
     photo(key, opts)             markup for a photo slot (see below)
     toast(text, kind)            a short notification
     confirm(opts) -> Promise     a styled confirmation dialog

   Motion is skipped entirely under prefers-reduced-motion, and the
   reveal styles only apply once this script has added .ms-motion to
   <html>, so content is never left hidden.
   ============================================================ */

(function () {
  'use strict';

  var doc = document.documentElement;
  var reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  var fine = window.matchMedia('(hover: hover) and (pointer: fine)');
  if (!reduce.matches) doc.classList.add('ms-motion');

  function esc(v) {
    return String(v == null ? '' : v)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  /* ---------- Reveal on scroll ------------------------------- */

  var io = ('IntersectionObserver' in window)
    ? new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (en.isIntersecting) { en.target.classList.add('is-in'); io.unobserve(en.target); }
        });
      }, { rootMargin: '0px 0px -6% 0px', threshold: 0.04 })
    : null;

  /* ---------- Parallax ---------------------------------------- */
  // [data-parallax="0.12"] drifts against the scroll by that factor.

  var drifting = [];
  var ticking = false;
  function drift() {
    ticking = false;
    var vh = window.innerHeight;
    drifting.forEach(function (el) {
      var r = el.getBoundingClientRect();
      if (r.bottom < -100 || r.top > vh + 100) return;
      var k = parseFloat(el.dataset.parallax) || 0.1;
      var off = (r.top + r.height / 2 - vh / 2) * -k;
      el.style.transform = 'translate3d(0,' + off.toFixed(1) + 'px,0)';
    });
  }
  function onScroll() { if (!ticking && drifting.length) { ticking = true; requestAnimationFrame(drift); } }
  window.addEventListener('scroll', onScroll, { passive: true });
  window.addEventListener('resize', onScroll);

  /* ---------- Magnetic buttons -------------------------------- */
  // [data-magnetic] leans a few pixels towards the pointer.

  function magnet(el) {
    if (el.dataset.msMag) return;
    el.dataset.msMag = '1';
    el.addEventListener('pointermove', function (e) {
      if (!fine.matches || reduce.matches) return;
      var r = el.getBoundingClientRect();
      var x = (e.clientX - r.left - r.width / 2) * 0.16;
      var y = (e.clientY - r.top - r.height / 2) * 0.24;
      el.style.transform = 'translate(' + x.toFixed(1) + 'px,' + y.toFixed(1) + 'px)';
    });
    el.addEventListener('pointerleave', function () { el.style.transform = ''; });
  }

  /* ---------- Spotlight --------------------------------------- */
  // [data-spotlight] gets --mx/--my for a soft highlight under the pointer.

  function spotlight(el) {
    if (el.dataset.msSpot) return;
    el.dataset.msSpot = '1';
    el.addEventListener('pointermove', function (e) {
      if (!fine.matches || reduce.matches) return;
      var r = el.getBoundingClientRect();
      el.style.setProperty('--mx', ((e.clientX - r.left) / r.width * 100).toFixed(1) + '%');
      el.style.setProperty('--my', ((e.clientY - r.top) / r.height * 100).toFixed(1) + '%');
    });
  }

  /* ---------- refresh ----------------------------------------- */

  function refresh(root, opts) {
    root = root || document;
    var instant = opts && opts.instant;

    root.querySelectorAll('[data-stagger]').forEach(function (group) {
      Array.prototype.forEach.call(group.children, function (c, i) {
        if (c.hasAttribute('data-reveal') && !c.style.getPropertyValue('--i')) {
          c.style.setProperty('--i', Math.min(i, 10));
        }
      });
    });

    root.querySelectorAll('[data-reveal]:not(.is-in)').forEach(function (el) {
      if (instant || !io || reduce.matches) {
        el.classList.add('is-in', 'is-now');
      } else {
        io.observe(el);
      }
    });

    drifting = reduce.matches ? [] : Array.prototype.slice.call(document.querySelectorAll('[data-parallax]'));
    onScroll();

    root.querySelectorAll('[data-magnetic]').forEach(magnet);
    root.querySelectorAll('[data-spotlight]').forEach(spotlight);
  }

  /* ---------- Photo slots ------------------------------------- */
  // Photos live in assets/ and are listed in assets/photos.js as
  // window.ICON_PHOTOS = { 'shop:fade-factory': 'assets/shops/fade-factory.jpg', ... }.
  // A key with no photo shows a tonal plate with a monogram or icon.

  var GLYPHS = {
    scissors: '<path d="M14 7.5 34 30M14 32.5 34 10" stroke-width="2.2"/><circle cx="9.5" cy="6.5" r="5"/><circle cx="9.5" cy="33.5" r="5"/>',
    comb: '<path d="M4 12h34v6H4zM8 18v14M13 18v14M18 18v14M23 18v14M28 18v14M33 18v14" stroke-width="2"/>',
    polish: '<path d="M15 4h10v9H15zM12 13h16l2 23H10z" stroke-width="2"/>',
    towel: '<path d="M6 10h28v20H6zM6 16h28M14 10v20" stroke-width="2"/>',
    drop: '<path d="M20 4c6 9 11 15 11 21a11 11 0 0 1-22 0c0-6 5-12 11-21z" stroke-width="2"/>',
    chair: '<path d="M13 4h14v4H13zM11 9h18v14H11zM6 22h28v6H6zM19 28h2v6h-2zM10 36h20" stroke-width="2"/>'
  };

  function photo(key, opts) {
    opts = opts || {};
    var src = window.ICON_PHOTOS && window.ICON_PHOTOS[key];
    var art = opts.mono
      ? '<span class="ms-ph__mono" aria-hidden="true">' + esc(opts.mono) + '</span>'
      : opts.glyph && GLYPHS[opts.glyph]
        ? '<svg class="ms-ph__icon" viewBox="0 0 40 40" fill="none" stroke="currentColor" aria-hidden="true">' + GLYPHS[opts.glyph] + '</svg>'
        : '';
    return '<figure class="ms-ph' + (opts.dark ? ' ms-ph--dark' : '') + (opts.zoom ? ' ms-ph--zoom' : '') +
        (opts.className ? ' ' + opts.className : '') + '"' +
        ' style="--ar:' + (opts.ratio || '4 / 5') + ';"' + (opts.reveal ? ' data-reveal="' + opts.reveal + '"' : '') + '>' +
      '<div class="ms-ph__art"' + (opts.parallax ? ' data-parallax="' + opts.parallax + '"' : '') + '>' + art + '</div>' +
      (src
        ? '<img src="' + esc(src) + '" alt="' + esc(opts.alt || '') + '" loading="' + (opts.eager ? 'eager' : 'lazy') + '"' +
          ' decoding="async"' + (opts.eager ? ' fetchpriority="high"' : '') +
          ' onload="this.classList.add(\'is-loaded\')">'
        : '') +
      (opts.label && !src ? '<figcaption class="ms-ph__label">' + esc(opts.label) + '</figcaption>' : '') +
    '</figure>';
  }

  /* ---------- Toasts ------------------------------------------ */

  var tray = null;
  function toast(text, kind) {
    if (!text) return;
    if (!tray) {
      tray = document.createElement('div');
      tray.className = 'ms-toasts';
      tray.setAttribute('role', 'status');
      tray.setAttribute('aria-live', 'polite');
      document.body.appendChild(tray);
    }
    var t = document.createElement('div');
    t.className = 'ms-toast' + (kind === 'bad' ? ' ms-toast--bad' : '');
    t.textContent = text;
    tray.appendChild(t);
    setTimeout(function () {
      t.classList.add('is-leaving');
      setTimeout(function () { t.remove(); }, reduce.matches ? 0 : 320);
    }, kind === 'bad' ? 5200 : 3200);
  }

  /* ---------- Confirm dialog ---------------------------------- */
  // Resolves true or false. Falls back to the browser's confirm()
  // where <dialog> is unsupported.

  function confirmBox(opts) {
    opts = opts || {};
    if (typeof HTMLDialogElement === 'undefined') {
      return Promise.resolve(window.confirm(opts.title + (opts.text ? '\n\n' + opts.text : '')));
    }
    return new Promise(function (resolve) {
      var d = document.createElement('dialog');
      d.className = 'ms-dialog';
      d.setAttribute('aria-labelledby', 'msDialogTitle');
      d.innerHTML =
        '<form method="dialog">' +
          '<div class="ms-dialog__body">' +
            '<h2 class="ms-dialog__title" id="msDialogTitle">' + esc(opts.title || 'Are you sure?') + '</h2>' +
            (opts.text ? '<p class="ms-dialog__text">' + esc(opts.text) + '</p>' : '') +
          '</div>' +
          '<div class="ms-dialog__acts">' +
            '<button class="ms-btn ms-btn--ghost" value="no" data-ms-cancel>' + esc(opts.cancel || 'Keep it') + '</button>' +
            '<button class="ms-btn ' + (opts.danger ? 'ms-btn--danger' : 'ms-btn--primary') + '" value="yes" data-ms-ok>' +
              esc(opts.ok || 'Yes') + '</button>' +
          '</div>' +
        '</form>';
      document.body.appendChild(d);
      d.addEventListener('close', function () {
        resolve(d.returnValue === 'yes');
        d.remove();
      });
      d.showModal();
      var keep = d.querySelector('[data-ms-cancel]');
      if (keep) keep.focus();
    });
  }

  window.MS = { refresh: refresh, photo: photo, toast: toast, confirm: confirmBox, esc: esc };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { refresh(document); });
  } else {
    refresh(document);
  }
})();
