import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/shared_profile/activity_deriver.dart';
import 'package:cinetrack/shared_profile/shared_profile_models.dart';

/// docs/82 §5.3 transition table (B8), 1:1. The deriver is pure: each row
/// builds the documents "before" and "after" the action and compares the
/// derived lists (newest first). `ep(X,n,TsEe)`, `done(X,n)`, `mov(Y)`,
/// `fav(Z)` as in the design.
final _since = DateTime.utc(2026, 10, 1);
final _old = DateTime.utc(2026, 1, 1); // favorited before the consent
final _now = DateTime.utc(2026, 10, 20);
DateTime _t(int minutes) => _since.add(Duration(hours: 1, minutes: minutes));

/// Mutable little library: series X (id 10), movies Y (20) and Z (30).
class _Lib {
  final Map<String, DateTime> xDates = {};
  final Set<String> xUndated = {};
  int xTotal = 6; // aired episodes of X (all in season 1)
  bool xFavorite = true;
  DateTime? yWatched;
  DateTime? zAdded;
  DateTime? zWatched;

  _Lib copy() => _Lib()
    ..xDates.addAll(xDates)
    ..xUndated.addAll(xUndated)
    ..xTotal = xTotal
    ..xFavorite = xFavorite
    ..yWatched = yWatched
    ..zAdded = zAdded
    ..zWatched = zWatched;

  void mark(String key, int at) => xDates[key] = _t(at);
  void unmark(String key) {
    xDates.remove(key);
    xUndated.remove(key);
  }

  List<FavoriteDoc> docs() => [
    if (xFavorite)
      FavoriteDoc(
        id: 10,
        mediaType: MediaType.tv,
        title: 'X',
        posterPath: '/x.jpg',
        overview: '',
        addedAt: _old,
        watchedEpisodes: {...xDates.keys, ...xUndated},
        watchedAt: xDates,
      ),
    FavoriteDoc(
      id: 20,
      mediaType: MediaType.movie,
      title: 'Y',
      posterPath: null,
      overview: '',
      addedAt: _old,
      watchedMovie: yWatched != null,
      lastWatchedAt: yWatched,
    ),
    if (zAdded != null)
      FavoriteDoc(
        id: 30,
        mediaType: MediaType.movie,
        title: 'Z',
        posterPath: null,
        overview: '',
        addedAt: zAdded!,
        watchedMovie: zWatched != null,
        lastWatchedAt: zWatched,
      ),
  ];

  List<String> derive({DateTime? since}) => [
    for (final a in ActivityDeriver.derive(
      docs(),
      actSince: since ?? _since,
      now: _now,
      isCompleted: (d) => d.id == 10 && d.watchedEpisodes.length >= xTotal,
    ))
      _label(a),
  ];
}

String _label(ActivityItem a) => switch (a.type) {
  ActivityType.favorited => 'fav(${_name(a.id)})',
  ActivityType.watchedMovie => 'mov(${_name(a.id)})',
  ActivityType.watchedEpisodes => 'ep(${_name(a.id)},${a.count},T${a.season}E${a.episode})',
  ActivityType.completedSeries => 'done(${_name(a.id)},${a.count})',
};

String _name(int id) => {10: 'X', 20: 'Y', 30: 'Z'}[id]!;

void main() {
  test('#1 four episodes one by one = one group', () {
    final l = _Lib();
    for (var e = 1; e <= 4; e++) {
      l.mark('1_$e', e);
    }
    expect(l.derive(), ['ep(X,4,T1E4)']);
  });

  test('#2 unmark T1E2 of the group: the counter goes down', () {
    final l = _Lib();
    for (var e = 1; e <= 4; e++) {
      l.mark('1_$e', e);
    }
    l.unmark('1_2');
    expect(l.derive(), ['ep(X,3,T1E4)']);
  });

  test('#3 unmark T1E4: "até" follows the highest left', () {
    final l = _Lib();
    for (var e = 1; e <= 4; e++) {
      l.mark('1_$e', e);
    }
    l.unmark('1_4');
    expect(l.derive(), ['ep(X,3,T1E3)']);
  });

  test('#4 unmark the only episode: the item disappears', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..yWatched = _t(2);
    expect(l.derive(), ['mov(Y)', 'ep(X,1,T1E1)']);
    final before = _Lib()
      ..yWatched = _t(1)
      ..mark('1_1', 2);
    expect(before.derive(), ['ep(X,1,T1E1)', 'mov(Y)']);
    before.unmark('1_1');
    expect(before.derive(), ['mov(Y)']);
  });

  test('#5 out of order: "até" = highest (season, episode)', () {
    final l = _Lib()
      ..mark('2_1', 1)
      ..mark('2_2', 2);
    expect(l.derive(), ['ep(X,2,T2E2)']);
    l.mark('1_5', 3);
    expect(l.derive(), ['ep(X,3,T2E2)']);
  });

  test('#6 another title in between starts a new group', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..mark('1_2', 2)
      ..yWatched = _t(3);
    expect(l.derive(), ['mov(Y)', 'ep(X,2,T1E2)']);
    l.mark('1_3', 4);
    expect(l.derive(), ['ep(X,1,T1E3)', 'mov(Y)', 'ep(X,2,T1E2)']);
  });

  test('#7 the title in between disappears: groups merge', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..mark('1_2', 2)
      ..yWatched = _t(3)
      ..mark('1_3', 4);
    l.yWatched = null;
    expect(l.derive(), ['ep(X,3,T1E3)']);
  });

  test('#8 whole series in bulk (one instant) completes it', () {
    final l = _Lib()..yWatched = _t(1);
    for (var e = 1; e <= 6; e++) {
      l.mark('1_$e', 5);
    }
    expect(l.derive(), ['done(X,6)', 'mov(Y)']);
  });

  test('#9 rest of the series in bulk after a group of the same title: merges and completes', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..mark('1_2', 2);
    for (var e = 3; e <= 6; e++) {
      l.mark('1_$e', 10);
    }
    expect(l.derive(), ['done(X,6)']);
  });

  test('#10 Desfazer of the bulk of #8: back to the list before', () {
    final before = _Lib()..yWatched = _t(1);
    final after = before.copy();
    for (var e = 1; e <= 6; e++) {
      after.mark('1_$e', 5);
    }
    // The undo restores marks AND dates (none here): exactly the "before" data.
    for (var e = 1; e <= 6; e++) {
      after.unmark('1_$e');
    }
    expect(after.derive(), before.derive());
    expect(after.derive(), ['mov(Y)']);
  });

  test('#11 a new episode airs: "concluiu" goes back to "assistiu"', () {
    final l = _Lib();
    for (var e = 1; e <= 6; e++) {
      l.mark('1_$e', 5);
    }
    expect(l.derive(), ['done(X,6)']);
    l.xTotal = 7;
    expect(l.derive(), ['ep(X,6,T1E6)']);
  });

  test('#12 favorite and watch within 10 min = only "assistiu"', () {
    final l = _Lib()
      ..zAdded = _t(0)
      ..zWatched = _t(10);
    expect(l.derive(), ['mov(Z)']);
  });

  test('#13 watched 2 h after favoriting: two items', () {
    final l = _Lib()
      ..zAdded = _t(0)
      ..zWatched = _t(120);
    expect(l.derive(), ['mov(Z)', 'fav(Z)']);
  });

  test('#14 removing the title removes its items', () {
    final l = _Lib()
      ..zAdded = _t(0)
      ..mark('1_1', 10)
      ..mark('1_2', 11)
      ..mark('1_3', 12);
    expect(l.derive(), ['ep(X,3,T1E3)', 'fav(Z)']);
    l.xFavorite = false;
    expect(l.derive(), ['fav(Z)']);
  });

  test('#15 "Recomendo" is never an activity', () {
    final l = _Lib()..mark('1_1', 1);
    final docs = l.docs().map((d) => d.copyWith(recommended: true)).toList();
    final list = ActivityDeriver.derive(
      docs,
      actSince: _since,
      now: _now,
      isCompleted: (_) => false,
    );
    expect(list.map(_label), l.derive());
  });

  test('#16 a mark made by the old app (no date) changes nothing', () {
    final l = _Lib()..mark('1_1', 1);
    final before = l.derive();
    l.xUndated.add('1_2');
    expect(l.derive(), before);
  });

  test('#17 turning "Atividades" off and on again starts empty (new actSince)', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..yWatched = _t(2);
    expect(l.derive(), isNotEmpty);
    expect(l.derive(since: _t(3)), isEmpty);
  });

  test('#18 unmark and re-mark: the new date moves it to the top', () {
    final l = _Lib()
      ..mark('1_1', 1)
      ..yWatched = _t(2);
    expect(l.derive(), ['mov(Y)', 'ep(X,1,T1E1)']);
    l
      ..unmark('1_1')
      ..mark('1_1', 3);
    expect(l.derive(), ['ep(X,1,T1E1)', 'mov(Y)']);
  });

  test('#19 ten items: a new one pushes the oldest out; undoing it brings it back', () {
    final docs = <FavoriteDoc>[
      for (var i = 0; i < 10; i++)
        FavoriteDoc(
          id: 100 + i,
          mediaType: MediaType.movie,
          title: 'M$i',
          posterPath: null,
          overview: '',
          addedAt: _old,
          watchedMovie: true,
          lastWatchedAt: _t(i),
        ),
    ];
    List<int> ids(List<FavoriteDoc> d) => [
      for (final a in ActivityDeriver.derive(
        d,
        actSince: _since,
        now: _now,
        isCompleted: (_) => false,
      ))
        a.id,
    ];
    expect(ids(docs), [for (var i = 9; i >= 0; i--) 100 + i]);
    final extra = FavoriteDoc(
      id: 999,
      mediaType: MediaType.movie,
      title: 'New',
      posterPath: null,
      overview: '',
      addedAt: _old,
      watchedMovie: true,
      lastWatchedAt: _t(30),
    );
    final more = ids([...docs, extra]);
    expect(more, hasLength(kMaxActivities));
    expect(more.first, 999);
    expect(more, isNot(contains(100)));
    expect(ids(docs), contains(100));
  });

  test('#20 reader: unknown type or malformed item is ignored, the rest shown', () {
    final good = ActivityItem(
      type: ActivityType.watchedMovie,
      id: 20,
      mediaType: 'movie',
      title: 'Y',
      at: _t(1),
    );
    final raw = [
      {'type': 'rated', 'id': 1, 'mediaType': 'movie', 'title': 'F4', 'at': _t(2)},
      {'type': 'favorited', 'id': 'x', 'mediaType': 'movie', 'title': 'bad', 'at': _t(2)},
      {'type': 'favorited', 'id': 3, 'mediaType': 'book', 'title': 'bad', 'at': _t(2)},
      'not a map',
      good.toJson(),
    ];
    expect(ActivityItem.parseList(raw), [good]);
    expect(ActivityItem.parseList('nope'), isEmpty);
  });

  group('edges', () {
    test('events before the consent never appear; dates in the future are clamped to now', () {
      final l = _Lib()..xDates['1_1'] = _since.subtract(const Duration(minutes: 1));
      expect(l.derive(), isEmpty);
      final future = _Lib()..xDates['1_1'] = _now.add(const Duration(days: 3));
      final list = ActivityDeriver.derive(
        future.docs(),
        actSince: _since,
        now: _now,
        isCompleted: (_) => false,
      );
      expect(list.single.at, _now);
    });

    test('a completed series with no dates never becomes "concluiu"', () {
      final l = _Lib()..xUndated.addAll({for (var e = 1; e <= 6; e++) '1_$e'});
      expect(l.derive(), isEmpty);
    });
  });
}
