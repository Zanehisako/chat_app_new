/* global firebase */
self.addEventListener('notificationclick', (event) => {
  const rawLink = event.notification.data?.chatAppLink;
  if (!rawLink) return;

  let link;
  try {
    link = new URL(rawLink, self.location.origin);
  } catch (_) {
    return;
  }
  if (link.origin !== self.location.origin) return;

  event.stopImmediatePropagation();
  event.notification.close();
  event.waitUntil(
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then(async (windowClients) => {
        const client = windowClients.find((candidate) =>
          candidate.url.startsWith(self.location.origin),
        );
        if (client) {
          await client.navigate(link.toString());
          return client.focus();
        }
        return self.clients.openWindow(link.toString());
      }),
  );
});

importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');
importScripts('/firebase-config.js');

self.skipWaiting();
self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      caches.keys().then((keys) =>
        Promise.all(
          keys
            .filter((key) =>
              key === 'flutter-app-manifest' ||
              key === 'flutter-temp-cache' ||
              key === 'flutter-app-cache'
            )
            .map((key) => caches.delete(key)),
        ),
      ),
    ]),
  );
});

const config = self.firebaseConfig;

if (config && config.apiKey && config.projectId && config.messagingSenderId) {
  firebase.initializeApp(config);
  firebase.messaging();
}
