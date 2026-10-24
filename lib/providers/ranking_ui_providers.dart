import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ranking/ranking_filter.dart';
import 'providers.dart';
import 'social_providers.dart';

/// Screen side of the ranking (Fatia 3): the last filter of the session and
/// how the 4 entries open `/ranking`.

/// The last filter shown in this session (memory only, docs/90 T2): dropped
/// when the account or the friendships period changes (RNF6).
final rankingLastFilterProvider = StateProvider<RankingFilter?>((ref) {
  ref.watch(currentUidProvider);
  ref.watch(socialPeriodProvider);
  return null;
});

/// Opens the ranking with `go` (docs/91 §9, spike of Fatia 3: with
/// `optionURLReflectsImperativeAPIs = false` a `push` never reaches the
/// address bar, so a reload would lose the filter). [from] is where the
/// AppBar's "Voltar" leads (the stack is not kept by `go`); it travels as the
/// route's `extra`, a plain string that survives the history.
void openRanking(BuildContext context, WidgetRef ref, {String? from}) {
  final filter = ref.read(rankingLastFilterProvider) ?? RankingFilter.standard;
  context.go(filter.location(), extra: from);
}
