/// No system share sheet here (Android / iOS / desktop builds of the app have
/// none wired; the web build uses `navigator.share`). The invite section then
/// offers only "Copiar".
const shareSupported = false;

Future<bool> shareLink({required String title, required String text, required String url}) async =>
    false;
