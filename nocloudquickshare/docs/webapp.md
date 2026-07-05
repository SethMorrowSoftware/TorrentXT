# The Web-App Demo (`webapp/`)

`webapp/` is a small, self-contained **single-page web app** that ships as sample
content for **No Cloud Quick Share**. It is not part of any extension and it is not
required to run Quick Share — it exists purely to *demonstrate*, in one page,
everything the built-in web host can do. Point Quick Share at this folder, share it
over Tor or a direct web link, open the address, and you are looking at the demo.

Read this after `../README.md`: it explains what the demo is, how the host serves it,
and the one design constraint (relative paths) that lets the same folder work over
both transports.

## What it is

A dependency-free SPA — plain HTML/CSS/JS, **no build step, no framework, no CDN, no
external fonts** — that makes **no network calls other than to the serving folder
itself**. Because of that it runs unchanged offline, over Tor, and under a strict CSP.
The five tabs (`Home`, `Gallery`, `Media`, `Backend`, `About`) are real client-side
routes, each wired to a specific host capability.

## What it demonstrates

| Capability | Where in the demo | How the host is exercised |
|---|---|---|
| **Static hosting, correct MIME** | every file | one of each interesting type — `.html .css .js .json .webmanifest .svg .png .wav` — served with the right content type |
| **HTTP Range** (stream + seek) | **Media** tab | `<audio src="assets/chime.wav">`; scrubbing issues a byte-range request instead of a full download |
| **SPA routing, refresh-safe** | all tabs | routes are pushed with `history.pushState`; the host falls back to `index.html` for any unknown route (`qsSiteSpaTarget`) and `app.js` restores the view from `location.pathname` |
| **Live backend route** | **Backend** tab + startup | `GET /_qs/info` is answered by the stack script (`qsHttpRoute` -> `qsHttpReply`); the tab pretty-prints the JSON, and startup uses its `mode` field for the transport badge |
| **Raster + vector images** | **Gallery** tab | six `.svg` pieces + one `.png`, with the list fetched from `data.json` at runtime |
| **Service worker (secure context)** | **About** tab | `sw.js` registers only when `window.isSecureContext` — proving a Tor `.onion` counts as secure while plain-http does not |
| **PWA manifest** | `site.webmanifest` | installable app metadata, icon, `standalone` display, relative `start_url`/`scope` |
| **Tor vs. web awareness** | header badge + About | `.onion` hostname / `/_qs/info` `mode` drive "Served over Tor" / "Served over the web" / "Static preview" |
| **Light + dark** | `app.css` | `prefers-color-scheme` + CSS custom properties, one stylesheet |

## How the host serves it

Quick Share is an OpenXTalk stack (`../src/nocloudquickshare.livecodescript`) that runs
a small streaming HTTP host. Serving the demo is entirely a runtime action — nothing is
compiled or copied:

1. Open `nocloudquickshare.livecodescript` in OpenXTalk and run it.
2. Drag **this `webapp` folder** onto the drop area (or use the Choose a folder button).
3. Share it:
   - **Over Tor** — the app is served at the onion root, `http://<addr>.onion/`. Tor
     Browser treats a `.onion` as a **secure context**, so the About tab's
     service-worker check registers and lights up.
   - **Over a direct web link** — pick the **Web link** method; the app is served under
     `http://<ip>:<port>/<token>/` and opens in any browser.
4. *(Optional)* enable the LAN-only **web editing** option, set a password, and open the
   link with **`/_edit`** appended to edit these files from a browser on your LAN. The
   service worker deliberately does no caching, so edits show up immediately.

### The routes the host provides for it

- **SPA fallback (`qsSiteSpaTarget`).** Any request that looks like an app route but is
  not an existing file is answered with `index.html`. That is what makes deep links and
  refresh work: refresh on `.../backend` and the host returns the shell, then `app.js`
  reads the path and re-renders the Backend view.
- **Dynamic route (`GET /_qs/info`).** Registered in the stack with
  `qsHttpRoute "GET","/_qs/info",<handler>` and answered with `qsHttpReply`. It returns
  JSON including a `mode` field (`tor` / `clearweb`) that the demo uses to label the
  transport. Add your own with `qsHttpRoute "GET","/api/thing","myHandler"` replying via
  `qsHttpReply`.
- **HTTP Range.** The host serves partial content, so the `<audio>` element can stream
  and seek `assets/chime.wav`.

## The one design constraint: relative paths

Every asset URL and every generated link is **relative**, never rooted at `/`. The
router in `app.js` derives its base by stripping a known route segment off
`location.pathname`. That single rule is why the *same untouched folder* works both at
the root (`/`, over Tor) and under `/<token>/` (over a web link) with **no `<base>` tag
and no rebuild**. The manifest follows suit: `start_url` and `scope` are `./`.

If you add pages or assets, keep paths relative (`assets/foo.svg`, not `/assets/foo.svg`)
or you will break the web-link (token-prefixed) case.

## Files

```
index.html          shell: relative <link>/<script>, header, nav, footer, manifest link
app.css             one stylesheet, light + dark via prefers-color-scheme
app.js              dependency-free router + views (base-path aware; transport detection)
data.json           gallery manifest, fetched at runtime
site.webmanifest    PWA manifest (installable; relative start_url/scope)
sw.js               minimal service worker - registers only in a secure context; NO caching
assets/
  logo.svg          app mark / favicon
  art-01..06.svg    gallery artwork (pure SVG)
  photo.png         a raster image (image/png) for the Range/Gallery demos
  chime.wav         a short tone for the HTTP-Range streaming/seek demo
```

## Editing notes for contributors

- **Keep every path relative** (see above) — the single most important rule.
- **`sw.js` must stay cache-free.** It has no `fetch` handler on purpose so live edits
  through `/_edit` are never masked by a stale cached file. Do not add caching without a
  very good reason.
- **The demo must degrade gracefully in a plain static preview** (opened as files, or
  from a non–Quick Share server): the Backend tab and transport badge already fail closed
  with a clear message when `/_qs/info` is unreachable. Preserve that.
- **Stay self-contained** — no CDN, no external fonts, no third-party network calls — so
  the demo keeps working offline, over Tor, and under a strict CSP.
- User-facing copy says **"No Cloud Quick Share."** Match that wording if you add UI text.
