// A deliberately minimal service worker. Its only job here is to prove that a service
// worker CAN register - which the browser allows ONLY in a secure context. Over Tor a
// .onion origin is treated as secure, so this registers and activates; over a plain
// http:// web link it will not register at all (and the About page says so).
//
// It intentionally has NO 'fetch' handler and does NO caching, so the live demo can
// never serve a stale file - handy while you are editing the folder with the built-in
// LAN editor. It just takes control of open pages so the status shows up immediately.
self.addEventListener('install', function () {
  self.skipWaiting();
});
self.addEventListener('activate', function (event) {
  event.waitUntil(self.clients.claim());
});
