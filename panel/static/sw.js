/* Kill-switch service worker for the panel origin.
 *
 * Why this file exists:
 * Before the panel vhost was added, this hostname fell through to the
 * Sub-Store default vhost, and Sub-Store's PWA registered /sw.js on THIS
 * origin. That stale worker kept serving the Sub-Store app shell from its
 * cache, so visits showed Sub-Store until a hard refresh.
 *
 * The panel itself never registers a service worker. This script exists only
 * to replace the old registration at the same URL, wipe its caches, and
 * unregister itself. It is inert otherwise.
 */
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    try {
      const keys = await caches.keys();
      await Promise.all(keys.map((k) => caches.delete(k)));
    } catch (err) { /* ignore */ }

    try {
      await self.registration.unregister();
    } catch (err) { /* ignore */ }

    try {
      const clients = await self.clients.matchAll({ type: 'window' });
      await Promise.all(clients.map((c) => c.navigate(c.url).catch(() => {})));
    } catch (err) { /* ignore */ }
  })());
});
