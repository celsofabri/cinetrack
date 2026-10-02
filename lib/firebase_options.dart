// Firebase configuration for project `cinetrack-d9398`.
//
// These identifiers are public by design (ADR-003): access is protected by
// Firestore Security Rules and by restricting the API key per domain/app, not
// by hiding this file. Only the web app is registered so far; Android and iOS
// throw until `flutterfire configure` is run for them, and `initFirebase()`
// then falls back to the catalog-only mode.
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    throw UnsupportedError(
      'Firebase is only configured for web. Run `flutterfire configure` to '
      'add Android/iOS.',
    );
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyBuLIGJu1Jv5bIKMVfCUYtg5fLRj-UmcLA',
    appId: '1:654575580795:web:375d77f2295f2d567ed4de',
    messagingSenderId: '654575580795',
    projectId: 'cinetrack-d9398',
    authDomain: 'cinetrack-d9398.firebaseapp.com',
    storageBucket: 'cinetrack-d9398.firebasestorage.app',
  );
}
