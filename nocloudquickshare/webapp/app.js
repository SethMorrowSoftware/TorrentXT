/* No Cloud Quick Share Web App Demo - a tiny dependency-free single-page app.
 *
 * The whole point is to exercise what the QuickShare host can do:
 *   - many static asset types with correct MIME (svg, png, wav, css, js, json, webmanifest)
 *   - HTTP Range (the <audio> element streams + seeks the .wav)
 *   - client-side ROUTING that survives a refresh, because the server falls back to
 *     index.html for any unknown path that looks like a route (qsSiteSpaTarget)
 *   - a live BACKEND route (GET /_qs/info) fetched at runtime
 *   - the same files working at the root (over Tor) AND under /<token>/ (web link)
 *
 * The base-path trick: every asset uses a RELATIVE URL, and the router computes its
 * base by stripping a known route off location.pathname - so no build step, no <base>,
 * and it does not matter whether we sit at "/" or "/<abc123>/".
 */
(function () {
  'use strict';

  var ROUTES = [
    { id: '',        label: 'Home' },
    { id: 'gallery', label: 'Gallery' },
    { id: 'media',   label: 'Media' },
    { id: 'backend', label: 'Backend' },
    { id: 'about',   label: 'About' }
  ];
  var NAMED = ROUTES.map(function (r) { return r.id; }).filter(Boolean);

  var view = document.getElementById('view');
  var nav = document.getElementById('nav');
  var info = null;                 // cached /_qs/info result, or false if unavailable

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  // --- base + route derivation (works at "/" or "/<token>/") ------------------
  function base() {
    var p = location.pathname.replace(/\/+$/, '');       // drop trailing slash(es)
    for (var i = 0; i < NAMED.length; i++) {
      var seg = '/' + NAMED[i];
      if (p === seg || p.slice(-seg.length) === seg) { p = p.slice(0, p.length - seg.length); break; }
    }
    return (p || '') + '/';
  }
  function route() {
    var p = location.pathname.replace(/\/+$/, '');
    var b = base().replace(/\/+$/, '');
    var r = p.slice(b.length).replace(/^\/+/, '');
    return r || '';
  }
  function href(id) { return base() + id; }

  // --- transport detection (via the live backend route, else a heuristic) -----
  function loadInfo() {
    return fetch(href('_qs/info'), { headers: { 'accept': 'application/json' } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .catch(function () { return null; });
  }
  function paintTransport() {
    var el = document.getElementById('transport');
    if (!el) return;
    var onion = /\.onion$/i.test(location.hostname);
    if (info && info.mode === 'tor' || onion) {
      el.textContent = 'Served over Tor'; el.className = 'badge tor';
    } else if (info && info.mode === 'clearweb') {
      el.textContent = 'Served over the web'; el.className = 'badge web';
    } else if (info) {
      el.textContent = 'Served by No Cloud Quick Share'; el.className = 'badge web';
    } else {
      el.textContent = 'Static preview'; el.className = 'badge';
    }
  }

  // --- views ------------------------------------------------------------------
  function vHome() {
    return '' +
      '<section class="hero">' +
        '<h1>It works &mdash; from a folder you shared.</h1>' +
        '<p>This whole single-page app is being served straight out of a shared folder by ' +
        'No Cloud Quick Share. Same files, whether it reached you over Tor or a direct web link.</p>' +
        '<div class="pills">' +
          '<span class="pill">Static assets</span><span class="pill">Correct MIME</span>' +
          '<span class="pill">HTTP Range</span><span class="pill">SPA routing</span>' +
          '<span class="pill">Live backend</span><span class="pill">Tor or web</span>' +
        '</div>' +
      '</section>' +
      '<div class="card"><h2>Take the tour</h2>' +
        '<p class="muted">Use the tabs above. Every tab is a real client-side route: change to ' +
        '<b>Gallery</b> or <b>Backend</b>, then <b>refresh</b> &mdash; the page still loads, because the ' +
        'server hands any unknown route back to <kbd>index.html</kbd> and this script restores the view.</p>' +
        '<div class="row"><a class="btn" data-route="gallery" href="' + esc(href('gallery')) + '">See the gallery</a>' +
        '<a class="btn ghost" data-route="backend" href="' + esc(href('backend')) + '">Call the backend</a></div>' +
      '</div>';
  }

  function vGallery() {
    return '<div class="card"><h2>Gallery</h2>' +
      '<p class="muted">Images served as ordinary files with the right content type &mdash; six vector ' +
      '<kbd>.svg</kbd> pieces plus a raster <kbd>.png</kbd>. The list itself is fetched from ' +
      '<kbd>data.json</kbd> at runtime.</p>' +
      '<div id="gal" class="grid"><p class="muted">Loading&hellip;</p></div></div>';
  }
  function fillGallery() {
    var box = document.getElementById('gal');
    fetch(href('data.json')).then(function (r) { return r.json(); }).then(function (d) {
      var items = (d && d.gallery) || [];
      if (!items.length) { box.innerHTML = '<p class="muted">No items.</p>'; return; }
      box.innerHTML = items.map(function (it) {
        return '<figure class="tile"><img loading="lazy" src="' + esc(it.file) + '" alt="' + esc(it.title) +
          '"><figcaption class="cap"><b>' + esc(it.title) + '</b><span>' + esc(it.note) + '</span></figcaption></figure>';
      }).join('');
    }).catch(function () { box.innerHTML = '<p class="muted">Could not load data.json.</p>'; });
  }

  function vMedia() {
    return '<div class="card media"><h2>Media &amp; Range</h2>' +
      '<p class="muted">The host supports <b>HTTP Range</b>, so a browser can stream and <b>seek</b> ' +
      'without downloading the whole file. Scrub the audio &mdash; that seek is a Range request.</p>' +
      '<audio controls preload="metadata" src="assets/chime.wav"></audio>' +
      '<p class="muted" style="margin:.3em 0 1.1em">A short C-major chime (<kbd>chime.wav</kbd>).</p>' +
      '<img loading="lazy" src="assets/photo.png" alt="A generated gradient" width="640" height="400">' +
      '<p class="muted">A raster <kbd>photo.png</kbd> served as <kbd>image/png</kbd>.</p></div>';
  }

  function vBackend() {
    return '<div class="card"><h2>Live backend</h2>' +
      '<p class="muted">Not just static files: the host answers dynamic routes from the stack script. ' +
      'This calls the built-in <kbd>GET /_qs/info</kbd> and shows what comes back.</p>' +
      '<div class="row"><button class="btn" id="ping">Call /_qs/info</button>' +
      '<span id="pingstat" class="status muted"></span></div>' +
      '<pre class="code" id="pingout">(press the button)</pre>' +
      '<p class="muted" style="margin-top:1em">Add your own with <kbd>qsHttpRoute "GET","/api/thing","myHandler"</kbd> ' +
      'in the stack, replying via <kbd>qsHttpReply</kbd>.</p></div>';
  }
  function wireBackend() {
    var btn = document.getElementById('ping');
    var out = document.getElementById('pingout');
    var stat = document.getElementById('pingstat');
    if (!btn) return;
    btn.addEventListener('click', function () {
      stat.textContent = 'requesting...'; stat.className = 'status muted';
      var t0 = (window.performance && performance.now) ? performance.now() : 0;
      fetch(href('_qs/info')).then(function (r) {
        var ms = t0 ? Math.max(1, Math.round(performance.now() - t0)) : null;
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text().then(function (txt) {
          var pretty = txt; try { pretty = JSON.stringify(JSON.parse(txt), null, 2); } catch (e) {}
          out.textContent = pretty;
          stat.innerHTML = '<span class="ok">200 OK</span>' + (ms ? ' in ' + ms + ' ms' : '');
        });
      }).catch(function (e) {
        out.textContent = 'This route answers only when the folder is served by No Cloud Quick Share ' +
          '(not in a plain static preview).\n\n' + e;
        stat.innerHTML = '<span class="no">unavailable here</span>';
      });
    });
  }

  function vAbout() {
    var secure = (window.isSecureContext === true);
    var swOk = ('serviceWorker' in navigator);
    var rows = [
      ['ok', 'Static hosting', 'Every file (html/css/js/svg/png/wav/json/webmanifest) is served with the right MIME type.'],
      ['ok', 'SPA routing', 'Unknown routes fall back to index.html, so deep links and refresh work.'],
      ['ok', 'HTTP Range', 'Media streams and seeks without a full download.'],
      ['ok', 'Live backend', 'GET /_qs/info is answered by the stack; add your own routes.'],
      ['ok', 'Tor or web link', 'Relative paths mean the same folder works at the root (Tor) or under /<token>/ (web).'],
      [secure ? 'ok' : 'q', 'Secure context', secure
        ? 'This page is a secure context, so features like service workers are allowed (typical over a Tor .onion).'
        : 'This page is NOT a secure context (plain http). Service workers and some Web APIs are blocked here; a Tor .onion would enable them.'],
      ['q', 'Live editing', 'Turn on the LAN-only editor in Quick Share and open this folder with /_edit on the end to edit these files in the browser.']
    ];
    var list = rows.map(function (r) {
      return '<li><span class="dot ' + (r[0] === 'ok' ? '' : 'q') + '">' + (r[0] === 'ok' ? '✓' : '?') +
        '</span><span><span class="k">' + esc(r[1]) + '</span> &mdash; ' + esc(r[2]) + '</span></li>';
    }).join('');
    return '<div class="card"><h2>What this demo shows</h2><ul class="feat">' + list + '</ul>' +
      '<p class="status" id="swstat" style="margin-top:1.1em">' +
      (swOk ? 'Service worker: <span id="swval" class="muted">checking&hellip;</span>'
            : 'Service worker: <span class="no">not supported by this browser</span>') + '</p></div>' +
      '<div class="card"><h2>Host it yourself</h2><p class="muted">In No Cloud Quick Share, drag this ' +
      '<kbd>webapp</kbd> folder onto the drop area, then share it over Tor or pick ' +
      '<b>Web link</b>. Open the link and you are looking at this page.</p></div>';
  }
  function wireAbout() {
    var val = document.getElementById('swval');
    if (!val) return;
    if (window.isSecureContext && 'serviceWorker' in navigator) {
      navigator.serviceWorker.register(href('sw.js')).then(function () {
        val.textContent = 'registered + active (secure context).'; val.className = 'ok';
      }).catch(function (e) { val.textContent = 'registration failed (' + e + ').'; val.className = 'no'; });
    } else {
      val.textContent = 'unavailable here - needs a secure context (Tor .onion or https).'; val.className = 'no';
    }
  }

  var VIEWS = {
    '':        { html: vHome,    after: null },
    'gallery': { html: vGallery, after: fillGallery },
    'media':   { html: vMedia,   after: null },
    'backend': { html: vBackend, after: wireBackend },
    'about':   { html: vAbout,   after: wireAbout }
  };

  // --- render + routing -------------------------------------------------------
  function buildNav() {
    nav.innerHTML = ROUTES.map(function (r) {
      return '<a data-route="' + r.id + '" href="' + esc(href(r.id)) + '">' + esc(r.label) + '</a>';
    }).join('');
  }
  function render() {
    var r = route();
    if (!VIEWS[r]) r = '';
    Array.prototype.forEach.call(nav.children, function (a) {
      a.className = (a.getAttribute('data-route') === r) ? 'on' : '';
    });
    var v = VIEWS[r];
    view.innerHTML = v.html();
    window.scrollTo(0, 0);
    if (v.after) v.after();
  }
  function go(id) {
    try { history.pushState(null, '', href(id)); }
    catch (e) { location.href = href(id); return; }   // file:// fallback
    render();
  }

  document.addEventListener('click', function (e) {
    var a = e.target.closest ? e.target.closest('[data-route]') : null;
    if (!a) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.button) return;   // let new-tab work
    e.preventDefault();
    go(a.getAttribute('data-route'));
  });
  window.addEventListener('popstate', render);

  // --- boot -------------------------------------------------------------------
  buildNav();
  render();
  loadInfo().then(function (d) { info = d; paintTransport(); });
})();
