/* ============================================================
   ICON — shared interface layer (ui.js)
   Loaded by the customer page and the staff pages, after the page
   markup and before the page's own script. No dependencies.

   window.MS:
     refresh(root, { instant })   wire reveals, parallax and magnetic
                                  buttons in freshly rendered markup
     photo(key, opts)             markup for a photo slot (see below)
     scene(name, opts)            a drawn SVG scene for a kind of shop
                                  or service (barber chair, polish...)
     arrow(dir)                   the animated arrow used in links
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

  // Looping scene animations only run while their picture is on screen.
  var watched = [];
  var liveIo = ('IntersectionObserver' in window)
    ? new IntersectionObserver(function (entries) {
        entries.forEach(function (en) { en.target.classList.toggle('is-paused', !en.isIntersecting); });
      })
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

    root.querySelectorAll('[data-split]').forEach(split);
    root.querySelectorAll('[data-depth-root]').forEach(depthRoot);

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

    if (liveIo) {
      // Forget pictures a repaint has removed, then watch the new ones.
      watched = watched.filter(function (el) { if (el.isConnected) return true; liveIo.unobserve(el); return false; });
      root.querySelectorAll('.ms-ph--live').forEach(function (el) { liveIo.observe(el); watched.push(el); });
    }

    root.querySelectorAll('[data-magnetic]').forEach(magnet);
    root.querySelectorAll('[data-spotlight]').forEach(spotlight);
  }

  /* ---------- Split headlines --------------------------------- */
  // [data-split] wraps each word so a heading can rise in word by word
  // once it is revealed. Only plain-text headings are split.

  // Text and simple inline elements (<em>, <span>) are kept; anything
  // with nested markup is left alone.
  function split(el) {
    if (el.dataset.msSplit) return;
    if (Array.prototype.some.call(el.children, function (c) { return c.children.length; })) return;
    el.dataset.msSplit = '1';
    var n = 0, out = [];
    Array.prototype.forEach.call(el.childNodes, function (node) {
      var tag = node.nodeType === 1 ? node.tagName.toLowerCase() : null;
      var cls = tag && node.className ? ' class="' + esc(node.className) + '"' : '';
      String(node.textContent).split(/(\s+)/).forEach(function (w) {
        if (!w) return;
        if (/^\s+$/.test(w)) { out.push(' '); return; }
        var word = esc(w);
        if (tag) word = '<' + tag + cls + '>' + word + '</' + tag + '>';
        out.push('<span class="sw"><span style="--w:' + (n++) + '">' + word + '</span></span>');
      });
    });
    el.innerHTML = out.join('').replace(/ {2,}/g, ' ').trim();
  }

  /* ---------- Pointer depth ----------------------------------- */
  // Inside [data-depth-root], each [data-depth="0.4"] drifts with the
  // pointer by that much, so layered pieces separate in space.

  function depthRoot(el) {
    if (el.dataset.msDepth) return;
    el.dataset.msDepth = '1';
    var raf = 0, px = 0, py = 0;
    function apply() {
      raf = 0;
      el.querySelectorAll('[data-depth]').forEach(function (d) {
        var k = parseFloat(d.dataset.depth) || 0.2;
        d.style.translate = (px * k * 28).toFixed(1) + 'px ' + (py * k * 22).toFixed(1) + 'px';
      });
    }
    el.addEventListener('pointermove', function (e) {
      if (!fine.matches || reduce.matches) return;
      var r = el.getBoundingClientRect();
      px = (e.clientX - r.left) / r.width - 0.5;
      py = (e.clientY - r.top) / r.height - 0.5;
      if (!raf) raf = requestAnimationFrame(apply);
    });
    el.addEventListener('pointerleave', function () { px = 0; py = 0; if (!raf) raf = requestAnimationFrame(apply); });
  }

  /* ---------- Press ripple ------------------------------------ */

  document.addEventListener('pointerdown', function (e) {
    var b = e.target.closest && e.target.closest('.ms-btn, .pick, .choice, .shopcard');
    if (!b || b.disabled || reduce.matches) return;
    var r = b.getBoundingClientRect();
    var d = Math.max(r.width, r.height) * 2.2;
    var dot = document.createElement('span');
    dot.className = 'ms-ripple';
    dot.setAttribute('aria-hidden', 'true');
    dot.style.width = dot.style.height = d + 'px';
    dot.style.left = (e.clientX - r.left - d / 2) + 'px';
    dot.style.top = (e.clientY - r.top - d / 2) + 'px';
    b.appendChild(dot);
    setTimeout(function () { dot.remove(); }, 700);
  }, { passive: true });

  /* ---------- Arrows ------------------------------------------ */

  function arrow(dir) {
    return '<svg class="ms-arrow' + (dir === 'left' ? ' ms-arrow--left' : '') + '" viewBox="0 0 20 20" fill="none" stroke="currentColor"' +
      ' stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
      (dir === 'left' ? '<path d="M17 10H4M9 5l-5 5 5 5"/>' : '<path d="M3 10h13M11 5l5 5-5 5"/>') + '</svg>';
  }

  /* ---------- Drawn scenes ------------------------------------ */
  // Line drawings for the kinds of shop and service, used wherever a
  // real photo has not been added yet. Layers: a soft arch, the object
  // in fine line with champagne fills, and a few floating details.
  // Each scene is drawn in a 400 x 320 box (the hero in 400 x 500).

  var uid = 0;

  // Small pieces, placed with a transform
  function scissors(t) {
    return '<g transform="' + t + '">' +
      '<path class="sc-paper" d="M-6 6 C-2 -18 6 -46 16 -70 L20 -68 C14 -42 6 -14 4 8 Z"/>' +
      '<path class="sc-paper" d="M6 6 C2 -18 -6 -46 -16 -70 L-20 -68 C-14 -42 -6 -14 -4 8 Z"/>' +
      '<path d="M-6 6 C-2 -18 6 -46 16 -70 L20 -68 C14 -42 6 -14 4 8 Z M6 6 C2 -18 -6 -46 -16 -70 L-20 -68 C-14 -42 -6 -14 -4 8 Z"/>' +
      '<circle class="sc-acc" cx="-15" cy="26" r="13"/><circle class="sc-acc" cx="15" cy="26" r="13"/>' +
      '<circle class="sc-ground" cx="-15" cy="26" r="7"/><circle class="sc-ground" cx="15" cy="26" r="7"/>' +
      '<path d="M-6 10 L-9 15 M6 10 L9 15"/><circle class="sc-ink" cx="0" cy="-2" r="2.6"/></g>';
  }
  function comb(t) {
    var teeth = '';
    for (var x = -54; x <= 54; x += 7) teeth += 'M' + x + ' 8v' + (x > 10 ? 20 : 26);
    return '<g transform="' + t + '"><rect class="sc-paper" x="-62" y="-8" width="124" height="16" rx="4"/>' +
      '<rect x="-62" y="-8" width="124" height="16" rx="4"/><path d="' + teeth + '"/></g>';
  }
  function bottle(t, tall) {
    var h = tall ? 92 : 70;
    return '<g transform="' + t + '">' +
      '<rect class="sc-ink" x="-11" y="' + (-h - 34) + '" width="22" height="40" rx="5"/>' +
      '<rect class="sc-paper" x="-17" y="' + (-h + 4) + '" width="34" height="10" rx="2"/><rect x="-17" y="' + (-h + 4) + '" width="34" height="10" rx="2"/>' +
      '<rect class="sc-acc" x="-36" y="' + (-h + 14) + '" width="72" height="' + h + '" rx="18"/>' +
      '<rect x="-36" y="' + (-h + 14) + '" width="72" height="' + h + '" rx="18"/>' +
      '<path class="sc-shine" d="M-24 ' + (-h + 30) + 'v' + (h - 34) + '"/></g>';
  }
  function chair(t) {
    return '<g transform="' + t + '">' +
      '<rect class="sc-paper" x="-30" y="-150" width="60" height="22" rx="11"/><rect x="-30" y="-150" width="60" height="22" rx="11"/>' +
      '<path d="M0 -128v10"/>' +
      '<rect class="sc-acc" x="-40" y="-118" width="80" height="98" rx="20"/><rect x="-40" y="-118" width="80" height="98" rx="20"/>' +
      '<path class="sc-shine" d="M-26 -100v60"/>' +
      '<path class="sc-paper" d="M-40 -46h104a10 10 0 0 1 0 20h-104z"/><path d="M-40 -46h104a10 10 0 0 1 0 20h-104"/>' +
      '<rect class="sc-acc" x="-56" y="-22" width="128" height="28" rx="14"/><rect x="-56" y="-22" width="128" height="28" rx="14"/>' +
      '<path d="M58 6 l26 46h26"/>' +
      '<rect class="sc-paper" x="-10" y="6" width="20" height="46" rx="4"/><rect x="-10" y="6" width="20" height="46" rx="4"/>' +
      '<ellipse class="sc-ink" cx="0" cy="58" rx="58" ry="9"/></g>';
  }
  function pole(t, id) {
    var stripes = '';
    for (var y = -170; y < 150; y += 26) stripes += '<path class="sc-acc" d="M-20 ' + y + 'l40 -24v12l-40 24z"/>';
    return '<g transform="' + t + '"><circle class="sc-acc" cx="0" cy="-74" r="9"/><circle cx="0" cy="-74" r="9"/>' +
      '<clipPath id="' + id + '"><rect x="-12" y="-64" width="24" height="128" rx="12"/></clipPath>' +
      '<rect class="sc-paper" x="-12" y="-64" width="24" height="128" rx="12"/>' +
      '<g clip-path="url(#' + id + ')"><g class="sc-pole">' + stripes + '</g></g>' +
      '<rect x="-12" y="-64" width="24" height="128" rx="12"/><rect class="sc-ink" x="-16" y="64" width="32" height="8" rx="3"/></g>';
  }
  function car(t) {
    return '<g transform="' + t + '">' +
      '<path class="sc-acc" d="M-160 30 Q-158 0 -120 -4 L-70 -8 Q-40 -40 0 -44 L60 -44 Q90 -42 118 -10 L150 -4 Q168 0 168 26 L168 34 Q168 40 160 40 L-152 40 Q-160 40 -160 34 Z"/>' +
      '<path d="M-160 30 Q-158 0 -120 -4 L-70 -8 Q-40 -40 0 -44 L60 -44 Q90 -42 118 -10 L150 -4 Q168 0 168 26 L168 34 Q168 40 160 40 L-152 40 Q-160 40 -160 34 Z"/>' +
      '<path class="sc-paper" d="M-58 -8 Q-34 -34 0 -36 L50 -36 Q76 -34 100 -8 Z"/><path d="M-58 -8 Q-34 -34 0 -36 L50 -36 Q76 -34 100 -8 Z M22 -36 V-8"/>' +
      '<path d="M-150 14h14 M140 10h18"/>' +
      '<circle class="sc-ink" cx="-90" cy="42" r="24"/><circle class="sc-paper" cx="-90" cy="42" r="10"/>' +
      '<circle class="sc-ink" cx="100" cy="42" r="24"/><circle class="sc-paper" cx="100" cy="42" r="10"/></g>';
  }
  function sparkle(x, y, s, d) {
    return '<path class="sc-acc sc-twinkle" style="--d:' + d + 's;transform-origin:' + x + 'px ' + y + 'px" d="M' + x + ' ' + (y - s) +
      'Q' + (x + s * 0.18) + ' ' + (y - s * 0.18) + ' ' + (x + s) + ' ' + y + 'Q' + (x + s * 0.18) + ' ' + (y + s * 0.18) + ' ' + x + ' ' + (y + s) +
      'Q' + (x - s * 0.18) + ' ' + (y + s * 0.18) + ' ' + (x - s) + ' ' + y + 'Q' + (x - s * 0.18) + ' ' + (y - s * 0.18) + ' ' + x + ' ' + (y - s) + 'Z"/>';
  }
  function bubbles(list) {
    return list.map(function (b, i) {
      return '<circle class="sc-bubble sc-rise" style="--d:' + (i * 0.7).toFixed(1) + 's" cx="' + b[0] + '" cy="' + b[1] + '" r="' + b[2] + '"/>';
    }).join('');
  }
  function fl(inner, d) { return '<g class="sc-float" style="--d:' + d + 's">' + inner + '</g>'; }
  var ARCH = '<path class="sc-arch" d="M110 330V150a90 90 0 0 1 180 0v180z"/><path class="sc-arch-line" d="M98 330V150a102 102 0 0 1 204 0v180"/>';

  var SCENES = {
    barbers: function (id) {
      return ARCH + pole('translate(62 190)', id) + chair('translate(196 268)') +
        fl(scissors('translate(330 108) rotate(28) scale(0.72)'), 0.4) + sparkle(318, 214, 9, 1.2) + sparkle(96, 64, 7, 2.1);
    },
    hair: function () {
      return ARCH + comb('translate(210 238) rotate(-12)') + fl(scissors('translate(196 150) rotate(-24) scale(1.25)'), 0) +
        sparkle(310, 92, 10, 0.6) + sparkle(98, 120, 7, 1.8);
    },
    beard: function () {
      return ARCH +
        '<g transform="translate(150 200)"><path class="sc-paper" d="M-6 -86 C-30 -128 30 -128 6 -86 Z"/><ellipse class="sc-acc" cx="0" cy="-92" rx="34" ry="30"/>' +
          '<path d="M-34 -92a34 30 0 0 1 68 0"/><rect class="sc-ink" x="-20" y="-64" width="40" height="10" rx="3"/>' +
          '<path class="sc-paper" d="M-16 -54h32l-6 70h-20z"/><path d="M-16 -54h32l-6 70h-20z"/></g>' +
        fl('<g transform="translate(262 176) rotate(-34)"><path class="sc-paper" d="M-74 -12h86a10 10 0 0 1 10 10v4a10 10 0 0 1 -10 10h-86l-12 -12z"/>' +
          '<path d="M-74 -12h86a10 10 0 0 1 10 10v4a10 10 0 0 1 -10 10h-86l-12 -12z M-60 4h60"/>' +
          '<path class="sc-acc-line" d="M22 4 q44 6 78 40"/><circle class="sc-ink" cx="22" cy="4" r="4"/></g>', 0.5) +
        sparkle(312, 84, 9, 1.4) + bubbles([[118, 108, 5], [96, 140, 3], [134, 86, 3]]);
    },
    nails: function () {
      return ARCH + bottle('translate(176 266)', true) + fl(bottle('translate(268 270) rotate(10) scale(0.72)'), 0.6) +
        '<path class="sc-acc-line" d="M70 278c40 -16 70 -6 98 -22"/>' +
        '<circle class="sc-acc" cx="96" cy="94" r="10"/><circle class="sc-ink" cx="122" cy="80" r="7"/><circle class="sc-paper" cx="104" cy="70" r="6"/><circle cx="104" cy="70" r="6"/>' +
        sparkle(318, 108, 10, 1.1);
    },
    skin: function () {
      return ARCH +
        '<g transform="translate(196 270)"><ellipse class="sc-ink" cx="0" cy="-140" rx="14" ry="18"/><rect class="sc-paper" x="-6" y="-124" width="12" height="40" rx="3"/><rect x="-6" y="-124" width="12" height="40" rx="3"/>' +
          '<rect class="sc-ink" x="-20" y="-96" width="40" height="18" rx="4"/><rect class="sc-acc" x="-40" y="-78" width="80" height="94" rx="24"/><rect x="-40" y="-78" width="80" height="94" rx="24"/>' +
          '<path class="sc-shine" d="M-26 -60v56"/></g>' +
        fl('<path class="sc-acc" d="M276 150c0 -18 14 -30 14 -30s14 12 14 30a14 14 0 0 1 -28 0z"/><path d="M276 150c0 -18 14 -30 14 -30s14 12 14 30a14 14 0 0 1 -28 0z"/>', 0.3) +
        fl('<path class="sc-paper" d="M96 210c10 -40 50 -56 74 -50c-6 26 -36 58 -74 50z"/><path d="M96 210c10 -40 50 -56 74 -50c-6 26 -36 58 -74 50z M100 206 c20 -14 40 -28 64 -42"/>', 1.1) +
        sparkle(120, 96, 8, 1.6);
    },
    spa: function () {
      return ARCH +
        '<ellipse class="sc-ink" cx="200" cy="282" rx="80" ry="16"/><ellipse class="sc-acc" cx="200" cy="254" rx="62" ry="18"/><ellipse cx="200" cy="254" rx="62" ry="18"/>' +
        '<ellipse class="sc-paper" cx="200" cy="224" rx="46" ry="15"/><ellipse cx="200" cy="224" rx="46" ry="15"/><ellipse class="sc-acc" cx="200" cy="198" rx="30" ry="12"/><ellipse cx="200" cy="198" rx="30" ry="12"/>' +
        fl('<path class="sc-steam" d="M182 170c-10 -16 10 -24 0 -42M204 166c-10 -16 10 -24 0 -42M226 170c-10 -16 10 -24 0 -42"/>', 0) +
        '<g transform="translate(316 270)"><circle class="sc-paper" r="24"/><circle r="24"/><path d="M0 -12a12 12 0 1 1 -12 12a6 6 0 0 1 6 -6"/></g>' +
        sparkle(104, 104, 9, 0.9);
    },
    wash: function () {
      return '<path class="sc-arch" d="M40 330V170a160 120 0 0 1 320 0v160z"/>' + car('translate(200 236)') +
        fl('<path class="sc-water" d="M70 120c40 30 70 40 120 44M330 112c-40 30 -80 44 -130 52"/>', 0.2) +
        bubbles([[96, 160, 9], [124, 128, 5], [292, 150, 11], [318, 116, 6], [260, 120, 4], [150, 170, 4]]) + sparkle(204, 86, 10, 1.2);
    },
    other: function () {
      return ARCH + sparkle(200, 190, 54, 0) + sparkle(276, 110, 14, 1.2) + sparkle(126, 116, 10, 2);
    },
    hero: function (id) {
      return '<path class="sc-arch" d="M64 520V210a136 136 0 0 1 272 0v310z"/><path class="sc-arch-line" d="M48 520V210a152 152 0 0 1 304 0v310"/>' +
        '<g class="sc-rays"><path d="M200 70v-36M140 86l-18 -30M260 86l18 -30"/></g>' +
        chair('translate(200 430) scale(1.2)') + pole('translate(30 300) scale(0.9)', id) +
        fl(scissors('translate(318 196) rotate(30) scale(0.8)'), 0) +
        fl(bottle('translate(88 238) rotate(-12) scale(0.5)'), 1.3) +
        bubbles([[332, 380, 9], [350, 340, 5], [314, 344, 4]]) +
        sparkle(126, 150, 10, 0.4) + sparkle(290, 120, 7, 1.6) + sparkle(352, 270, 6, 2.4);
    }
  };
  SCENES['nail-salon'] = SCENES.nails;
  SCENES['car-wash'] = SCENES.wash;

  // Tones of the one champagne, so a row of cards isn't uniform.
  var TONES = ['#D8C19A', '#E2CDB2', '#CBB083', '#DCC7A4'];

  function scene(name, opts) {
    opts = opts || {};
    var draw = SCENES[name] || SCENES.other;
    var id = 'msc' + (++uid);
    // Cards crop in close on the object; the hero keeps its whole stage.
    var box = name === 'hero' ? '0 0 400 520' : (name === 'wash' || name === 'car-wash') ? '28 40 352 290' : '44 36 312 294';
    var tone = opts.tone ? ' style="--sc-acc:' + TONES[opts.tone % TONES.length] + '"' : '';
    return '<svg class="ms-sc ms-sc--' + esc(name) + (opts.flip ? ' ms-sc--flip' : '') + '" viewBox="' + box + '"' + tone +
      ' preserveAspectRatio="xMidYMax meet" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"' +
      ' aria-hidden="true" focusable="false">' + draw(id) + '</svg>';
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
    // A scene can carry a monogram behind it, so shops of one kind differ.
    if (opts.scene) {
      var mono = opts.mono ? '<span class="ms-ph__mono ms-ph__mono--back" aria-hidden="true">' + esc(opts.mono) + '</span>' : '';
      var artScene = '<span class="ms-ph__glow" aria-hidden="true"></span>' + mono + scene(opts.scene, opts);
      opts = Object.assign({}, opts, { mono: null, glyph: null, sceneArt: artScene });
    }
    var art = opts.sceneArt ? opts.sceneArt : opts.mono
      ? '<span class="ms-ph__mono" aria-hidden="true">' + esc(opts.mono) + '</span>'
      : opts.glyph && GLYPHS[opts.glyph]
        ? '<svg class="ms-ph__icon" viewBox="0 0 40 40" fill="none" stroke="currentColor" aria-hidden="true">' + GLYPHS[opts.glyph] + '</svg>'
        : '';
    return '<figure class="ms-ph' + (opts.dark ? ' ms-ph--dark' : '') + (opts.zoom ? ' ms-ph--zoom' : '') +
        (opts.sceneArt ? ' ms-ph--scene' : '') + (opts.live ? ' ms-ph--live' : '') + (src ? ' ms-ph--photo' : '') +
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

  window.MS = { refresh: refresh, photo: photo, scene: scene, arrow: arrow, toast: toast, confirm: confirmBox, esc: esc };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () { refresh(document); });
  } else {
    refresh(document);
  }
})();
