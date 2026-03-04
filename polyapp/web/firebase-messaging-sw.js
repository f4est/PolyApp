const firebaseConfig = {
  apiKey: "AIzaSyCfvxHLcCFetoO8taKHnvimiaanpR49UfE",
  authDomain: "polyapp-by-youxu.firebaseapp.com",
  projectId: "polyapp-by-youxu",
  storageBucket: "polyapp-by-youxu.firebasestorage.app",
  messagingSenderId: "1049365186984",
  appId: "1:1049365186984:web:88abcd6b81d796605ef59d",
  measurementId: "G-S3EVGJW4TR",
};

importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging-compat.js');

firebase.initializeApp(firebaseConfig);

const messaging = firebase.messaging();
