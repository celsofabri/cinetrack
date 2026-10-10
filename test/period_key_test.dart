import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/progress_calculator.dart';
import 'package:cinetrack/shared_profile/period_key.dart';

/// docs/82 §5.1 (B1): periods in the OWNER's zone, absolute dates.
void main() {
  const saoPaulo = -180;

  group('periodKey', () {
    test('31/10/2026 23:59 in São Paulo is still October; 01/11 00:00 is November', () {
      // 23:59 local (UTC-3) = 02:59 UTC on 01/11.
      expect(periodKey(DateTime.utc(2026, 11, 1, 2, 59), saoPaulo), (
        month: '2026-10',
        year: '2026',
      ));
      expect(periodKey(DateTime.utc(2026, 11, 1, 3), saoPaulo), (month: '2026-11', year: '2026'));
    });

    test('31/12 -> 01/01 turns the year', () {
      expect(periodKey(DateTime.utc(2027, 1, 1, 2, 59), saoPaulo), (
        month: '2026-12',
        year: '2026',
      ));
      expect(periodKey(DateTime.utc(2027, 1, 1, 3), saoPaulo), (month: '2027-01', year: '2027'));
    });

    test('UTC owner (tz = 0) and the extremes of the rules', () {
      expect(periodKey(DateTime.utc(2026, 10, 31, 23, 59), 0), (month: '2026-10', year: '2026'));
      expect(periodKey(DateTime.utc(2026, 10, 31, 10), 840), (month: '2026-11', year: '2026'));
      expect(periodKey(DateTime.utc(2026, 11, 1, 13), -840), (month: '2026-10', year: '2026'));
    });

    test('a local DateTime is read as the instant it represents', () {
      final instant = DateTime.utc(2026, 11, 1, 2, 59);
      expect(periodKey(instant.toLocal(), saoPaulo), periodKey(instant, saoPaulo));
    });
  });

  group('normalizeTz', () {
    test('-0 becomes a plain 0 (web writes -0 as a double; the rule needs an int)', () {
      final v = normalizeTz(-0.0);
      expect(v, 0);
      expect(v.isNegative, isFalse);
      expect(normalizeTz(0), 0);
      expect(normalizeTz(double.nan), 0);
    });

    test('clamped to the rules range and rounded', () {
      expect(normalizeTz(-900), kMinTzMinutes);
      expect(normalizeTz(900), kMaxTzMinutes);
      expect(normalizeTz(-180.4), -180);
      expect(normalizeTz(330), 330);
    });

    test('deviceTzMinutes is the offset of the given moment', () {
      final now = DateTime.now();
      expect(deviceTzMinutes(now), normalizeTz(now.timeZoneOffset.inMinutes));
    });
  });

  group('injectable clock for "already aired" (B1)', () {
    final tomorrow = DateTime.utc(2026, 10, 11);
    final ep = EpisodeCache(episodeNumber: 2, name: 'E2', airDate: tomorrow, watched: false);

    test('hasAiredAt uses the given instant; hasAired keeps the device clock', () {
      expect(ep.hasAiredAt(DateTime.utc(2026, 10, 10)), isFalse);
      expect(ep.hasAiredAt(tomorrow), isTrue);
      const noDate = EpisodeCache(episodeNumber: 1, name: 'E1', airDate: null, watched: false);
      expect(noDate.hasAiredAt(DateTime.utc(2000)), isTrue);
      expect(ep.hasAired, ep.hasAiredAt(DateTime.now()));
    });

    test('ProgressCalculator answers for the injected now', () {
      final season = SeasonCache(
        seasonNumber: 1,
        episodes: [
          EpisodeCache(
            episodeNumber: 1,
            name: 'E1',
            airDate: DateTime.utc(2026, 1, 1),
            watched: true,
          ),
          ep,
        ],
      );
      expect(
        ProgressCalculator.compute([season], now: DateTime.utc(2026, 10, 10)).isCaughtUp,
        isTrue,
      );
      expect(
        ProgressCalculator.compute([season], now: DateTime.utc(2026, 10, 12)).isCaughtUp,
        isFalse,
      );
    });
  });
}
