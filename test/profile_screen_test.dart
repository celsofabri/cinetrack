import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cinetrack/auth/auth_failure.dart';
import 'package:cinetrack/data/profile_data_source.dart';
import 'package:cinetrack/models/favorite_doc.dart';
import 'package:cinetrack/models/media_type.dart';
import 'package:cinetrack/models/tv_season_summary.dart';
import 'package:cinetrack/providers/account_providers.dart';
import 'package:cinetrack/screens/profile_screen.dart';
import 'package:cinetrack/widgets/privacy_summary.dart';

import 'support/cloud_overrides.dart';
import 'support/fake_auth_repository.dart';
import 'support/in_memory_favorites_data_source.dart';

FavoriteDoc _movie(int id, {bool watched = false}) => FavoriteDoc(
      id: id,
      mediaType: MediaType.movie,
      title: 'Filme $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
      watchedMovie: watched,
    );

FavoriteDoc _show(int id, Set<String> watched) => FavoriteDoc(
      id: id,
      mediaType: MediaType.tv,
      title: 'Serie $id',
      posterPath: null,
      overview: '',
      addedAt: DateTime(2026),
      watchedEpisodes: watched,
      seasonSummaries: const [TvSeasonSummary(seasonNumber: 1, name: 'T1', episodeCount: 20)],
    );

class _Rig {
  final cloud = FakeCloud();
  late final FakeAuthRepository auth;
  final opened = <Uri>[];
  bool openerWorks = true;

  _Rig({AppUserOrNull user = true}) {
    auth = FakeAuthRepository(initialUser: user ? kAna : null);
  }

  Widget app() => ProviderScope(
        overrides: [
          ...cloudOverrides(auth: auth, cloud: cloud),
          urlOpenerProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return openerWorks;
          }),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      );

  Map<String, FavoriteDoc> get ana => cloud.server.putIfAbsent('uid-ana', () => {});
}

typedef AppUserOrNull = bool;

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 200, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  group('statistics', () {
    testWidgets('show the real numbers and change after the data changes', (tester) async {
      final rig = _Rig();
      rig.ana
        ..['1-movie'] = _movie(1, watched: true)
        ..['2-movie'] = _movie(2)
        ..['3-movie'] = _movie(3)
        ..['10-tv'] = _show(10, {'1_1', '1_2', '1_3'})
        ..['11-tv'] = _show(11, {'1_1', '1_2'});
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Suas estatísticas'));

      expect(find.bySemanticsLabel('Favoritos: 5'), findsOneWidget);
      expect(find.bySemanticsLabel('Filmes favoritos: 3'), findsOneWidget);
      expect(find.bySemanticsLabel('Séries favoritas: 2'), findsOneWidget);
      expect(find.bySemanticsLabel('Filmes assistidos: 1'), findsOneWidget);
      expect(find.bySemanticsLabel('Episódios assistidos: 5'), findsOneWidget);
      expect(find.bySemanticsLabel('Séries concluídas: 0'), findsOneWidget);

      rig.cloud.write('uid-ana', (docs) => docs['10-tv'] = _show(10, {'1_1', '1_2', '1_3', '1_4'}));
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Episódios assistidos: 6'), findsOneWidget);
    });

    testWidgets('a brand new account shows zeros, not an error', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Suas estatísticas'));
      expect(find.bySemanticsLabel('Favoritos: 0'), findsOneWidget);
    });
  });

  group('nickname', () {
    testWidgets('empty or blank is rejected with a message and nothing is saved', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Definir apelido'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(find.textContaining('não pode ficar vazio'), findsOneWidget);
      expect(rig.cloud.profiles['uid-ana'], isNull);
    });

    testWidgets('saves the trimmed nickname and shows it in the profile', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Definir apelido'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  Aninha  ');
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(rig.cloud.profiles['uid-ana']!.nickname, 'Aninha');
      expect(find.text('Aninha'), findsOneWidget);
      expect(find.text('Editar apelido'), findsOneWidget);
      expect(find.text('Apelido salvo.'), findsOneWidget);
    });

    testWidgets('the field stops at 40 characters', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Definir apelido'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'x' * 60);

      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text.length, 40);
    });

    testWidgets('works offline (does not wait for the server) and can go back to the Google name',
        (tester) async {
      final rig = _Rig();
      rig.cloud.profiles['uid-ana'] = const UserProfile(nickname: 'Antigo');
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      rig.cloud.offline = true;

      await tester.tap(find.text('Editar apelido'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Usar nome do Google'));
      await tester.pumpAndSettle();

      expect(rig.cloud.profiles['uid-ana']!.nickname, isNull);
      expect(find.text('Ana Teste'), findsWidgets);
    });
  });

  group('privacy', () {
    testWidgets('summary is shown and the policy link opens the static page', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Privacidade'));

      expect(find.textContaining('Não usamos anúncios nem telemetria'), findsOneWidget);
      await tester.tap(find.text('Política de privacidade'));
      await tester.pumpAndSettle();

      expect(rig.opened.single.toString(), kPrivacyPolicyUrl);
      expect(kPrivacyPolicyUrl, endsWith('/privacidade.html'));
    });

    testWidgets('if the link cannot be opened the user is told', (tester) async {
      final rig = _Rig()..openerWorks = false;
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await _scrollTo(tester, find.text('Política de privacidade'));

      await tester.tap(find.text('Política de privacidade'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Não foi possível abrir a política'), findsOneWidget);
    });
  });

  group('delete account dialog', () {
    Future<void> openDialog(WidgetTester tester) async {
      await _scrollTo(tester, find.text('Excluir minha conta e dados'));
      await tester.tap(find.text('Excluir minha conta e dados'));
      await tester.pumpAndSettle();
    }

    testWidgets('explains the consequences, focus starts on the safe button, Esc cancels',
        (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openDialog(tester);

      expect(find.text('Excluir conta e dados?'), findsOneWidget);
      expect(find.textContaining('Não dá para desfazer'), findsOneWidget);
      expect(find.textContaining('entrar com o Google de novo'), findsOneWidget);

      final cancel = find.widgetWithText(TextButton, 'Cancelar');
      expect(tester.widget<TextButton>(cancel).autofocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Excluir conta e dados?'), findsNothing);
      expect(rig.auth.reauthCalls, 0);
      expect(rig.ana, hasLength(1));
    });

    testWidgets('keyboard only: Tab reaches the destructive button and Enter confirms',
        (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openDialog(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab); // Cancelar -> Excluir
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(rig.auth.reauthCalls, 1);
      expect(rig.ana, isEmpty);
      expect(rig.auth.deleteUserCalls, 1);
      expect(find.text('Conta excluída.'), findsOneWidget);
    });

    testWidgets('Cancelar does nothing', (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openDialog(tester);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(rig.auth.reauthCalls, 0);
      expect(rig.ana, hasLength(1));
    });

    testWidgets('while running: progress shown, buttons disabled, Esc does not close',
        (tester) async {
      final rig = _Rig();
      rig.auth.reauthGate = Completer<void>();
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openDialog(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Excluir minha conta e dados'));
      await tester.pump();

      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('Confirmando sua identidade'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('Excluir conta e dados?'), findsOneWidget);

      rig.auth.reauthGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Excluir conta e dados?'), findsNothing);
    });

    testWidgets('failure is shown in the dialog (live region) and can be retried', (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      rig.auth.reauthFailure = const AuthFailure(AuthFailureKind.wrongAccount);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      await openDialog(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Excluir minha conta e dados'));
      await tester.pumpAndSettle();

      expect(find.textContaining('mesma conta Google'), findsOneWidget);
      expect(rig.ana, hasLength(1));

      rig.auth.reauthFailure = null;
      await tester.tap(find.text('Tentar novamente'));
      await tester.pumpAndSettle();

      expect(rig.ana, isEmpty);
      expect(find.text('Conta excluída.'), findsOneWidget);
    });

    testWidgets('offline: clear message, nothing deleted, no popup', (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();
      rig.cloud.offline = true;
      await tester.pumpAndSettle();
      await openDialog(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Excluir minha conta e dados'));
      await tester.pumpAndSettle();

      expect(find.textContaining('para excluir a conta'), findsOneWidget);
      expect(rig.auth.reauthCalls, 0);
      expect(rig.ana, hasLength(1));
    });
  });

  group('interrupted deletion', () {
    testWidgets('the profile offers to finish it and finishing deletes everything', (tester) async {
      final rig = _Rig();
      rig.ana['1-movie'] = _movie(1);
      rig.cloud.profiles['uid-ana'] = const UserProfile(deleting: true);
      await tester.pumpWidget(rig.app());
      await tester.pumpAndSettle();

      expect(find.textContaining('foi iniciada e não terminou'), findsOneWidget);
      await tester.tap(find.text('Concluir exclusão'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Excluir minha conta e dados').last);
      await tester.pumpAndSettle();

      expect(rig.ana, isEmpty);
      expect(rig.cloud.profiles['uid-ana'], isNull);
    });
  });
}
