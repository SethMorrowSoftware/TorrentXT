# TorrentXT Web App Demo

A small, self-contained **single-page app** meant to be hosted straight out of a folder
by the **Quick Share** demo (`../torrent-quickshare.livecodescript`) - over **Tor** or a
**direct web link**. It exists to show off, in one place, everything the built-in web
host can do.

## Host it

1. Open `torrent-quickshare.livecodescript` in OpenXTalk and run it.
2. Drag **this `quickshare-webapp` folder** onto the drop area.
3. Share it:
   - **Over Tor** - the app is served at the onion root (`http://<addr>.onion/`). Tor
     Browser treats a `.onion` as a **secure context**, so the service-worker check on
     the About page lights up.
   - **Over a web link** - tick **Share via web link**; the app lives under
     `http://<ip>:<port>/<token>/`. Open it in any browser.
4. (Optional) tick **Enable web editing**, set a password, and open the link with
   `/_edit` on the end to edit these files from a browser on your LAN.

Because every asset path is **relative**, the exact same folder works at the root (Tor)
or under `/<token>/` (web link) with no build step and no `<base>` tag.

## What it demonstrates

| Feature | Where |
|---|---|
| Static hosting with correct **MIME types** | `.html .css .js .svg .png .wav .json .webmanifest` all served correctly |
| **SPA routing** with refresh support | the tabs are real routes; the server falls back to `index.html` for unknown routes (`qsSiteSpaTarget`) and `app.js` restores the view |
| **HTTP Range** (streaming + seek) | the **Media** tab scrubs `assets/chime.wav` |
| **Raster + vector images** | the **Gallery** tab (6 SVG + 1 PNG), list fetched from `data.json` |
| **Live backend route** | the **Backend** tab calls `GET /_qs/info` and shows the JSON |
| **Tor vs. web** awareness | the header badge and the **About** tab (secure-context / service-worker) |

## Files

```
index.html          shell: relative <link>/<script>, header, nav, footer
app.css             one stylesheet, light + dark via prefers-color-scheme
app.js              dependency-free router + views (base-path aware)
data.json           gallery manifest, fetched at runtime
site.webmanifest    PWA manifest (installable)
sw.js               minimal service worker (registers only in a secure context; no caching)
assets/
  logo.svg          app mark / favicon
  art-01..06.svg    gallery artwork (pure SVG)
  photo.png         a generated raster image (image/png)
  chime.wav         a short tone for the Range/streaming demo
```

Everything here is **self-contained** - no CDN, no external fonts, no network calls other
than to the folder itself - so it runs unchanged offline, over Tor, and under a strict CSP.
