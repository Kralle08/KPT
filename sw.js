// KPT – zeigt Push-Erinnerungen an. Kein Zwischenspeichern, die App lädt immer frisch.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));

self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch { /* leere Nachricht */ }
  e.waitUntil(self.registration.showNotification(d.title || "KPT", {
    body: d.body || "Es gibt Neuigkeiten im Kochclub.",
    icon: "icon-192.png", badge: "icon-192.png", tag: d.tag || "kpt"
  }));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const offen = list.find(c => c.url.startsWith(self.registration.scope));
    return offen ? offen.focus() : self.clients.openWindow(self.registration.scope);
  }));
});
