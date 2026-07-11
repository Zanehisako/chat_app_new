/* global firebase */
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js');
importScripts('/firebase-config.js');

const config = self.firebaseConfig;

if (config && config.apiKey && config.projectId && config.messagingSenderId) {
  firebase.initializeApp(config);
  firebase.messaging();
}
