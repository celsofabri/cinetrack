import 'dart:js_interop';

/// Web side of [jsRoundTrip]: the value goes through a real JS object and
/// back (`jsify().dartify()`), the path of the web Firestore plugin
/// (docs/91 O2), so JS numbers arrive as the app sees them in production.
Object? jsRoundTrip(Object? v) => v.jsify().dartify();

const bool jsRoundTripIsReal = true;
