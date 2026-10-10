import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/activity_overlay.dart';
import 'package:cinetrack/data/server_clock.dart';

/// docs/82 §4.2 (A5): device clock corrected by the server offset.
void main() {
  test('without a sample it is the device clock (UTC)', () {
    final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 10, 12));
    expect(clock.now(), DateTime.utc(2026, 10, 10, 12));
    expect(clock.sampled, isFalse);
  });

  test('a confirmed own write sets the offset', () {
    var device = DateTime.utc(2026, 10, 10, 12);
    final clock = ServerClock(deviceNow: () => device);
    // Device 2 h late: the server says 14:00 for a mark stamped 12:00.
    expect(
      clock.sample(
        local: device,
        server: DateTime.utc(2026, 10, 10, 14),
        elapsed: const Duration(seconds: 1),
      ),
      isTrue,
    );
    device = device.add(const Duration(minutes: 5));
    expect(clock.now(), DateTime.utc(2026, 10, 10, 14, 5));
    expect(clock.offset, const Duration(hours: 2));
  });

  test('stale or absurd samples are ignored', () {
    final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 10, 12));
    final local = DateTime.utc(2026, 10, 10, 12);
    expect(
      clock.sample(
        local: local,
        server: local.add(const Duration(hours: 1)),
        elapsed: const Duration(minutes: 2),
      ),
      isFalse,
      reason: 'confirmation arrived too late: could be another device / the offline queue',
    );
    expect(
      clock.sample(
        local: local,
        server: local.add(const Duration(days: 3)),
        elapsed: Duration.zero,
      ),
      isFalse,
    );
    expect(clock.now(), local);
  });

  group('ActivityOverlay feeds the clock', () {
    test('only the first settled snapshot AFTER a pending one is a sample', () {
      final clock = ServerClock(deviceNow: () => DateTime.utc(2026, 10, 10, 12));
      final overlay = ActivityOverlay(clock: clock);
      final stampAt = DateTime.utc(2026, 10, 10, 12);
      overlay.stamp('1-tv', stampAt);
      // A settled snapshot that does not contain our write yet (old value).
      expect(
        overlay.resolve('1-tv', DateTime.utc(2026, 1, 1), pending: false),
        DateTime.utc(2026, 1, 1),
      );
      expect(clock.sampled, isFalse);

      overlay.stamp('1-tv', stampAt);
      expect(overlay.resolve('1-tv', null, pending: true), stampAt);
      expect(
        overlay.resolve('1-tv', DateTime.utc(2026, 10, 10, 12, 0, 30), pending: false),
        DateTime.utc(2026, 10, 10, 12, 0, 30),
      );
      expect(clock.sampled, isTrue);
      expect(clock.offset, const Duration(seconds: 30));
    });

    test('without a clock it behaves as before', () {
      final overlay = ActivityOverlay();
      final at = DateTime.utc(2026, 10, 10);
      overlay.stamp('k', at);
      expect(overlay.resolve('k', null, pending: true), at);
      expect(overlay.resolve('k', null, pending: false), isNull);
    });
  });
}
