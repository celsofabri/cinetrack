import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/data/export_data_source.dart';
import 'package:cinetrack/export/data_exporter.dart';
import 'package:cinetrack/export/export_serializer.dart';
import 'package:cinetrack/social/social_models.dart';

import 'support/fake_export_data_source.dart';

Future<Map<String, dynamic>> _export(FakeExportDataSource source, {int pageSize = 300}) async {
  final file = await runExport(
    source: source,
    from: ExportSource.server,
    now: () => DateTime.utc(2026, 10, 5),
    isCurrent: () => true,
    uid: 'uid-ana',
    pageSize: pageSize,
  );
  return jsonDecode(file.json) as Map<String, dynamic>;
}

void main() {
  test('without friendships: schema 2 with social null, everything else as before', () async {
    final json = await _export(FakeExportDataSource({'1-movie': fakeMovieDoc(1)}));
    expect(json['schemaVersion'], 2);
    expect(json.containsKey('social'), isTrue);
    expect(json['social'], isNull);
    expect((json['favorites'] as List), hasLength(1));
  });

  group('residue WITHOUT the pointer is exported too (docs/71 G6)', () {
    test('a failed last sweep left a pair, a request and a block: all in the file', () async {
      final at = DateTime.utc(2026, 9, 1);
      final source = FakeExportDataSource({'1-movie': fakeMovieDoc(1)}); // social == null
      source.socialLists[SocialExportKind.friends] = {
        'uid-ana_uid-bia': {
          'members': ['uid-ana', 'uid-bia'],
          'createdAt': at,
          'aName': 'Ana',
          'bName': 'Bia',
        },
      };
      source.socialLists[SocialExportKind.requestsSent] = {
        'uid-ana_uid-caio': {'from': 'uid-ana', 'to': 'uid-caio', 'toName': 'Caio', 'createdAt': at},
      };
      source.socialLists[SocialExportKind.blocks] = {
        'uid-zeca': {'blockedName': 'Zeca', 'createdAt': at},
      };
      final json = await _export(source);
      final social = json['social'] as Map<String, dynamic>;
      expect(social['handle'], isNull);
      expect(social['pointer'], isNull);
      expect((social['friends'] as List).single['uid'], 'uid-bia');
      expect((social['requestsSent'] as List).single['uid'], 'uid-caio');
      expect((social['blocks'] as List).single['uid'], 'uid-zeca');
      expect(source.socialCalls.map((c) => c.kind).toSet(), SocialExportKind.values.toSet());
      expect((json['favorites'] as List), hasLength(1));
    });

    test('no pointer and no residue: the 4 lists are asked and social stays null', () async {
      final source = FakeExportDataSource({'1-movie': fakeMovieDoc(1)});
      final json = await _export(source);
      expect(json['social'], isNull);
      expect(source.socialCalls, hasLength(SocialExportKind.values.length));
    });

    test('rules not published (lists denied) and no pointer: the export still works', () async {
      final source = FakeExportDataSource({'1-movie': fakeMovieDoc(1)})
        ..socialListFailure = const ExportReadException(
          ExportReadFailureKind.denied,
          code: 'permission-denied',
        );
      final json = await _export(source);
      expect(json['social'], isNull);
      expect((json['favorites'] as List), hasLength(1));
    });

    test('WITH the pointer a denied list is a real failure (nothing is silently missing)', () async {
      final source = FakeExportDataSource({})
        ..social = const RawSocial(social: {'handle': 'ana'})
        ..socialListFailure = const ExportReadException(
          ExportReadFailureKind.denied,
          code: 'permission-denied',
        );
      await expectLater(_export(source), throwsA(isA<ExportReadException>()));
    });
  });

  test('with friendships: handle, preferences, raw docs and uid + nickname of friends', () async {
    final at = DateTime.utc(2026, 9, 1);
    final source = FakeExportDataSource({})
      ..social = RawSocial(
        social: {'handle': 'ana', 'handleChangedAt': at, 'schemaVersion': 1},
        card: {
          'uid': 'uid-ana',
          'nickname': 'Ana',
          'photoURL': 'https://lh3.googleusercontent.com/a',
          'discoverable': false,
          'createdAt': at,
          'updatedAt': at,
          'futureField': 7,
        },
      );
    source.socialLists[SocialExportKind.friends] = {
      'uid-ana_uid-bia': {
        'members': ['uid-ana', 'uid-bia'],
        'createdAt': at,
        'aName': 'Ana',
        'bName': 'Bia',
        'bPhoto': 'https://lh3.googleusercontent.com/b',
      },
      'uid-ana_uid-zeca': {
        'members': ['uid-ana', 'uid-zeca'],
        'createdAt': at,
        'aName': 'Ana',
        'bName': 'Zeca',
      },
      // Ana is the second member here
      'uid-0_uid-ana': {
        'members': ['uid-0', 'uid-ana'],
        'createdAt': at,
        'aName': 'Zero',
        'bName': 'Ana',
      },
    };
    source.socialLists[SocialExportKind.requestsSent] = {
      'uid-ana_uid-x': {'from': 'uid-ana', 'to': 'uid-x', 'fromName': 'Ana', 'toName': 'Xis'},
    };
    source.socialLists[SocialExportKind.requestsReceived] = {
      'uid-y_uid-ana': {'from': 'uid-y', 'to': 'uid-ana', 'fromName': 'Yara', 'toName': 'Ana'},
    };
    source.socialLists[SocialExportKind.blocks] = {
      'uid-w': {'blockedName': 'Wil', 'createdAt': at},
    };

    final social = (await _export(source, pageSize: 2))['social'] as Map<String, dynamic>;
    expect(social['handle'], 'ana');
    expect(social['discoverable'], false);
    expect(social['photoVisible'], true);
    expect(((social['card'] as Map)['data'] as Map)['futureField'], 7);
    expect(((social['pointer'] as Map)['timestampFields']), ['handleChangedAt']);
    final friends = [for (final f in social['friends'] as List) (f['uid'], f['nickname'])];
    expect(friends, [('uid-0', 'Zero'), ('uid-bia', 'Bia'), ('uid-zeca', 'Zeca')]);
    expect(social['requestsSent'][0]['uid'], 'uid-x');
    expect(social['requestsReceived'][0]['nickname'], 'Yara');
    expect(social['blocks'][0]['uid'], 'uid-w');
    expect(social['counts'], {'friends': 3, 'requestsSent': 1, 'requestsReceived': 1, 'blocks': 1});
    // pages of 2 were really used (3 friends need a second page)
    final friendCalls = source.socialCalls.where((c) => c.kind == SocialExportKind.friends);
    expect(friendCalls.map((c) => c.cursor), [null, 'uid-ana_uid-bia']);
    // photos of other people never leave
    expect(jsonEncode(social['friends']), isNot(contains('googleusercontent')));
  });

  test('an unrecognized social document is reported with field names and types only', () async {
    final source = FakeExportDataSource({})
      ..social = const RawSocial(social: {'handle': 'ana'}, card: null);
    source.socialLists[SocialExportKind.friends] = {
      'odd': {'members': 'nope', 'bPhoto': 'https://lh3.googleusercontent.com/someone-else'},
    };
    final json = await _export(source);
    expect(json['social']['friends'][0]['fields'], {'members': 'string', 'bPhoto': 'string'});
    expect(jsonEncode(json['social']['friends']), isNot(contains('someone-else')));
    expect(json['issues'], [
      {'key': 'friendships/odd', 'reason': ExportIssue.notRecognized},
    ]);
  });

  test('a version-1 file (no social key) is still a valid subset of the format', () {
    final v1 = jsonDecode('{"schema":"cinetrack-export","schemaVersion":1,"favorites":[]}');
    expect(v1['schema'], kExportSchemaId);
    expect(v1['social'], isNull); // readers must treat a missing key as "no friendships"
  });

  test('server failure while reading social aborts instead of dropping it silently', () async {
    final source = FakeExportDataSource({})
      ..social = const RawSocial(social: {'handle': 'ana'})
      ..serverFailure = const ExportReadException(ExportReadFailureKind.unreachable);
    await expectLater(_export(source), throwsA(isA<ExportReadException>()));
  });
}
