import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/firestore_favorites_data_source.dart';
import 'package:cinetrack/data/social_payloads.dart';
import 'package:cinetrack/models/episode_cache.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/season_cache.dart';
import 'package:cinetrack/services/favorite_mapper.dart';
import 'package:cinetrack/shared_profile/shared_profile_builder.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';
import 'package:cinetrack/shared_profile/shared_profile_payloads.dart';

/// Golden test of the phase-2 payloads (docs/82 §13, docs/84 gate): what the
/// Dart app writes to `shared_profiles/{uid}` (SharedProfilePayloads) and the
/// `setEpisodes` updates with mark dates (FavoritePayloads) must equal
/// firestore_rules_test/fixtures/shared_profile_payloads.json, which
/// shared_profile_payloads.test.mjs replays against firestore.rules.
///   UPDATE_GOLDEN=1 flutter test test/shared_profile_payloads_golden_test.dart
/// then `npm test` in firestore_rules_test.
const _fixturePath = 'firestore_rules_test/fixtures/shared_profile_payloads.json';
const _uid = 'uid-ana';
final _now = DateTime.utc(2026, 10, 10, 15);
final _actSince = DateTime.utc(2026, 10, 1, 12);
final _member = DateTime.utc(2025, 3, 2, 10);

FavoriteDoc _series(
  int id, {
  Map<String, DateTime> dated = const {},
  Set<String> undated = const {},
  bool rec = false,
}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.tv,
  title: 'Série $id',
  posterPath: '/s$id.jpg',
  overview: '',
  addedAt: DateTime.utc(2025, 5, 1),
  lastWatchedAt: DateTime.utc(2026, 10, 9),
  watchedEpisodes: {...dated.keys, ...undated},
  watchedAt: dated,
  recommended: rec,
);

FavoriteDoc _movie(int id, {DateTime? watchedAt, DateTime? added, bool rec = false}) => FavoriteDoc(
  id: id,
  mediaType: MediaType.movie,
  title: 'Filme $id',
  posterPath: id.isEven ? '/m$id.jpg' : null,
  overview: '',
  addedAt: added ?? DateTime.utc(2025, 6, 1),
  lastWatchedAt: watchedAt,
  watchedMovie: watchedAt != null,
  recommended: rec,
);

/// A library with dated and undated marks, a completed series, recommended
/// titles, activity after the consent: realistic content for every section.
List<FavoriteDoc> _library() => [
  _series(
    1399,
    dated: {
      for (var e = 1; e <= 6; e++) '1_$e': DateTime.utc(2026, 10, 2 + e, 21),
      '2_1': DateTime.utc(2026, 9, 20, 22),
    },
    undated: {'0_1'},
    rec: true,
  ),
  _series(
    66732,
    dated: {'1_1': DateTime.utc(2026, 10, 9, 23, 30), '1_2': DateTime.utc(2026, 10, 9, 23, 30)},
  ),
  _series(1668, undated: {for (var e = 1; e <= 10; e++) '1_$e'}, rec: true),
  for (var i = 1; i <= 12; i++)
    _movie(
      100 + i,
      watchedAt: i <= 8 ? DateTime.utc(2026, 10, i % 9 + 1, 20) : null,
      added: i > 10 ? DateTime.utc(2026, 10, 5, 10) : null,
      rec: i.isOdd,
    ),
];

List<SeasonCache> _catalog(int tvId) => switch (tvId) {
  66732 => [
    SeasonCache(
      seasonNumber: 1,
      episodes: [
        for (var e = 1; e <= 2; e++)
          EpisodeCache(
            episodeNumber: e,
            name: 'E$e',
            airDate: DateTime.utc(2024, 1, e),
            watched: false,
            runtime: 50,
          ),
      ],
    ),
  ],
  _ => const [],
};

SharedProfileContent _content({int tz = -180, Set<SharedSection>? sections}) =>
    SharedProfileBuilder.build(
      _library(),
      catalog: _catalog,
      movieRuntime: (id) => id.isEven ? 110 : null,
      tvFallbackRuntime: (id) => id == 1399 ? 55 : null,
      sections: sections ?? SharedSection.values.toSet(),
      now: _now,
      tzMinutes: tz,
      actSince: _actSince,
      memberSince: _member,
    );

/// A document as already stored on the server (seeded with rules off).
Map<String, Object?> _stored(Set<SharedSection> sections, {int tz = -180}) {
  final c = _content(tz: tz);
  return {
    'v': 1,
    'calc': 1,
    'updatedAt': DateTime.utc(2026, 10, 8, 12),
    'tz': tz,
    'sharing': {for (final s in SharedSection.values.where(sections.contains)) s.field: true},
    if (sections.contains(SharedSection.activity)) 'actSince': _actSince,
    for (final s in SharedSection.values.where(sections.contains)) s.field: c.section(s),
  };
}

const _path = 'shared_profiles/$_uid';
const _favPath = 'users/$_uid/favorites/1399-tv';

Map<String, Object?> _scenario(
  SocialWrite write, {
  Map<String, Object?>? seed,
  bool social = false,
  String expect = 'allow',
  String? note,
}) => {
  'note': ?note,
  'uid': _uid,
  if (social) 'social': true,
  if (seed != null) 'seed': SharedProfilePayloads.jsonValue(seed),
  'expect': expect,
  'write': SharedProfilePayloads.toJson(write),
};

/// The favorite as stored (dates as DateTime) and as the app parses it.
Map<String, Object?> _favorite({
  Map<String, bool> eps = const {},
  Map<String, DateTime> epsAt = const {},
}) => {
  'id': 1399,
  'mediaType': 'tv',
  'title': 'Série 1399',
  'posterPath': '/s1399.jpg',
  'overview': '',
  'addedAt': DateTime.utc(2025, 5, 1),
  'lastWatchedAt': DateTime.utc(2026, 10, 9),
  'watchedMovie': false,
  'seasonSummaries': [
    {'seasonNumber': 1, 'name': 'Temporada 1', 'episodeCount': 24},
  ],
  'eps': eps,
  if (epsAt.isNotEmpty) 'epsAt': epsAt,
  'updatedAt': DateTime.utc(2026, 10, 9),
};

Map<String, Object?> _episodes(
  Map<String, Object?> stored,
  Map<String, bool> changes, {
  bool dates = true,
  Map<String, DateTime>? restore,
}) {
  final current = FavoriteMapper.fromMap('1399-tv', stored)!;
  final data = FirestoreFavoritesDataSource.episodesUpdate(
    changes,
    current: current,
    restoreDates: restore,
    datesEnabled: dates,
    instant: _now,
  );
  return _scenario(
    SocialWrite(SocialWriteMode.batch, [SocialOp.update(_favPath, data)]),
    seed: {_favPath: stored},
  );
}

Map<String, Object?> _scenarios() {
  final all = _content();
  final utc = _content(tz: 0);
  Set<SharedSection> only(SharedSection s) => {s};
  const stats = SharedSection.stats, activity = SharedSection.activity, recs = SharedSection.recs;
  SocialWrite on(SharedSection s, Set<SharedSection>? current, {SharedProfileContent? c}) =>
      SharedProfilePayloads.turnOn(
        _uid,
        section: s,
        content: c ?? all,
        current: current,
        now: _now,
      );
  SocialWrite recalc(Set<SharedSection> changed, {SharedProfileContent? c}) =>
      SharedProfilePayloads.recalc(
        _uid,
        content: c ?? all,
        changed: changed,
        now: _now,
        actSince: _actSince,
      );
  final day = {for (var e = 1; e <= 3; e++) '1_$e': DateTime.utc(2026, 10, 3, 21)};
  return {
    'turnOn_stats_create': _scenario(on(stats, null), social: true),
    'turnOn_activity_create': _scenario(on(activity, null), social: true),
    'turnOn_recs_create': _scenario(on(recs, null), social: true),
    'turnOn_stats_create_utc_owner': _scenario(
      on(stats, null, c: utc),
      social: true,
      note: 'tz = 0',
    ),
    'turnOn_activity_update': _scenario(
      on(activity, only(stats)),
      seed: {_path: _stored(only(stats))},
      social: true,
    ),
    'turnOn_recs_update': _scenario(
      on(recs, {stats, activity}),
      seed: {
        _path: _stored({stats, activity}),
      },
      social: true,
    ),
    'turnOn_stats_without_social': _scenario(
      on(stats, null),
      expect: 'deny',
      note: 'no friendships',
    ),
    'turnOff_stats_update': _scenario(
      SharedProfilePayloads.turnOff(_uid, section: stats, current: {stats, activity}),
      seed: {
        _path: _stored({stats, activity}),
      },
      social: true,
    ),
    'turnOff_activity_update': _scenario(
      SharedProfilePayloads.turnOff(_uid, section: activity, current: {stats, activity}),
      seed: {
        _path: _stored({stats, activity}),
      },
      social: true,
    ),
    'turnOff_last_section_deletes': _scenario(
      SharedProfilePayloads.turnOff(_uid, section: recs, current: only(recs)),
      seed: {_path: _stored(only(recs))},
      social: true,
    ),
    'recalc_stats_without_social': _scenario(
      recalc(only(stats)),
      seed: {
        _path: _stored({stats, activity}),
      },
      note: 'a recalculation makes no rule call (docs/82 §4.3)',
    ),
    'recalc_all_sections': _scenario(
      recalc(SharedSection.values.toSet()),
      seed: {_path: _stored(SharedSection.values.toSet())},
    ),
    'recalc_utc_owner': _scenario(
      recalc({stats, activity}, c: utc),
      seed: {
        _path: _stored({stats, activity}, tz: 0),
      },
    ),
    'recalc_stale_device_republishes_stats': _scenario(
      recalc(only(stats)),
      seed: {_path: _stored(only(activity))},
      expect: 'deny',
      note: 'stats turned off on another device: a late device cannot republish it',
    ),
    'pulse': _scenario(SharedProfilePayloads.pulse(_uid), seed: {_path: _stored(only(stats))}),
    'deleteOwn': _scenario(
      SharedProfilePayloads.deleteOwn(_uid),
      seed: {_path: _stored(only(stats))},
    ),
    'deleteOwn_missing': _scenario(SharedProfilePayloads.deleteOwn(_uid)),
    'setEpisodes_mark_with_date': _episodes(
      _favorite(eps: {'1_1': true}, epsAt: {'1_1': DateTime.utc(2026, 10, 2)}),
      {'1_2': true},
    ),
    'setEpisodes_mark_old_document_without_epsAt': _episodes(_favorite(eps: {'1_1': true}), {
      '1_2': true,
      '1_3': true,
    }),
    'setEpisodes_unmark_deletes_date': _episodes(
      _favorite(
        eps: {'1_1': true, '1_2': true},
        epsAt: {'1_1': DateTime.utc(2026, 10, 2), '1_2': DateTime.utc(2026, 10, 3)},
      ),
      {'1_2': false},
    ),
    'setEpisodes_orphan_cleanup': _episodes(
      _favorite(
        eps: {'1_1': true},
        epsAt: {'1_1': DateTime.utc(2026, 10, 2), '1_9': DateTime.utc(2026, 9, 1)},
      ),
      {'1_2': true},
    ),
    'setEpisodes_rules_not_confirmed': _episodes(_favorite(eps: {'1_1': true}), {
      '1_2': true,
      '1_1': false,
    }, dates: false),
    'setEpisodes_bulk_season_one_instant': _episodes(_favorite(), {
      for (var e = 1; e <= 24; e++) '1_$e': true,
    }),
    'undo_bulk_unmark_restores_dates': _episodes(_favorite(), {
      for (var e = 1; e <= 4; e++) '1_$e': true,
    }, restore: day),
  };
}

Map<String, Object?> _golden() => {
  'comment':
      'Generated by test/shared_profile_payloads_golden_test.dart (UPDATE_GOLDEN=1). Do not edit by hand.',
  'serverTimestamp': kServerTimestampJson,
  'deleteField': kDeleteFieldJson,
  'clientTimePlusPrefix': kClientTimePlusPrefix,
  'timestampPrefix': kTimestampJsonPrefix,
  'scenarios': _scenarios(),
};

void main() {
  test('Dart shared-profile payloads equal the fixture the rules suite replays', () {
    final golden = jsonDecode(jsonEncode(_golden()));
    final file = File(_fixturePath);
    if (Platform.environment['UPDATE_GOLDEN'] == '1') {
      file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(golden)}\n');
    }
    expect(file.existsSync(), isTrue, reason: 'run with UPDATE_GOLDEN=1 to create $_fixturePath');
    expect(
      golden,
      equals(jsonDecode(file.readAsStringSync())),
      reason: 'payloads changed: regenerate the fixture AND run npm test',
    );
  });

  test('the fixture covers every section, UTC owner, dates and orphans', () {
    final s = _scenarios();
    final text = jsonEncode(_golden());
    expect(
      s.keys,
      containsAll(['turnOn_stats_create_utc_owner', 'setEpisodes_orphan_cleanup', 'pulse']),
    );
    expect(text, contains('"tz":0'));
    expect(text, isNot(contains('"tz":-0')));
    expect(text, contains('"epsAt.1_9":"$kDeleteFieldJson"'));
    // ONE instant per write: the bulk season carries the same date 24 times.
    final bulk = jsonEncode(s['setEpisodes_bulk_season_one_instant']);
    expect('$kTimestampJsonPrefix${_now.toIso8601String()}'.allMatches(bulk).length, 24);
    // The rules-not-confirmed write is the phase-1 payload: no epsAt at all.
    expect(jsonEncode(s['setEpisodes_rules_not_confirmed']), isNot(contains('epsAt')));
  });

  test('recalculation never writes consent fields', () {
    for (final entry in _scenarios().entries.where(
      (e) => e.key.startsWith('recalc') || e.key == 'pulse',
    )) {
      final text = jsonEncode(entry.value);
      final data = jsonEncode(
        (((entry.value as Map)['write'] as Map)['ops'] as List).single['data'],
      );
      expect(data, isNot(contains('sharing')), reason: entry.key);
      expect(data, isNot(contains('actSince')), reason: entry.key);
      expect(text, contains(kServerTimestampJson), reason: entry.key);
    }
  });
}
