import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/app_user.dart';

/// docs/74 🟡-R1 / docs/75 N2: which photo the app uses for the signed-in user.
void main() {
  const top = 'https://lh3.googleusercontent.com/a/criada-na-conta';
  const google = 'https://lh3.googleusercontent.com/a/atual-do-google';

  test('the Google provider photo wins over the top-level photoURL '
      '(it is refreshed on every sign-in)', () {
    expect(
      pickPhotoUrl(
        topLevel: top,
        providers: const [
          (providerId: 'password', photoUrl: 'https://x.example/p.png'),
          (providerId: 'google.com', photoUrl: google),
        ],
      ),
      google,
    );
  });

  test('no Google provider data: top-level photoURL is used', () {
    expect(pickPhotoUrl(topLevel: top, providers: const []), top);
    expect(
      pickPhotoUrl(
        topLevel: top,
        providers: const [(providerId: 'password', photoUrl: 'https://x.example/p.png')],
      ),
      top,
    );
  });

  test('Google provider without a photo: null (never the stale top-level photo)', () {
    expect(
      pickPhotoUrl(topLevel: top, providers: const [(providerId: 'google.com', photoUrl: null)]),
      isNull,
    );
    expect(
      pickPhotoUrl(topLevel: top, providers: const [(providerId: 'google.com', photoUrl: ' ')]),
      isNull,
    );
    // ... also when another provider still has a photo.
    expect(
      pickPhotoUrl(
        topLevel: top,
        providers: const [
          (providerId: 'password', photoUrl: 'https://x.example/p.png'),
          (providerId: 'google.com', photoUrl: null),
        ],
      ),
      isNull,
    );
  });

  test('no photo anywhere: null', () {
    expect(pickPhotoUrl(topLevel: null, providers: const []), isNull);
    expect(
      pickPhotoUrl(topLevel: '', providers: const [(providerId: 'google.com', photoUrl: null)]),
      isNull,
    );
  });
}
