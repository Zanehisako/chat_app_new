{{flutter_js}}
{{flutter_build_config}}

(async () => {
  if ('serviceWorker' in navigator) {
    try {
      await navigator.serviceWorker.register('/firebase-messaging-sw.js');
      await navigator.serviceWorker.ready;
    } catch (error) {
      console.warn('Firebase messaging service worker registration failed.');
    }
  }
  await _flutter.loader.load();
})();
