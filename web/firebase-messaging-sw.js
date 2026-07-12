/* global firebase */
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
