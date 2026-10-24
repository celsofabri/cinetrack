import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/account_providers.dart';
import '../providers/providers.dart';
import '../providers/ranking_providers.dart';
import '../providers/ranking_ui_providers.dart';
import '../providers/shared_profile_providers.dart';
import '../providers/sharing_providers.dart';
import '../providers/social_providers.dart';
import '../ranking/ranking_filter.dart';
import '../ranking/ranking_models.dart';
import '../ranking/ranking_table.dart';
import '../ranking/ranking_texts.dart';
import '../shared_profile/sharing_texts.dart';
import '../widgets/app_shell.dart';
import '../widgets/ranking_widgets.dart';
import '../widgets/sharing_section.dart';
import 'friends_screen.dart' show kListJustRefreshedMessage;

/// Widest content of the ranking (centered on desktop).
const double kRankingMaxWidth = 720;

/// Filters side by side from this width (× text scale); stacked below it.
const double kRankingFiltersRowWidth = 600;

/// `/ranking` (docs/90 RF-V, RF-R, RF-E; docs/91 §9, §11). The filter lives
/// in the address (T2); the data comes from [rankingControllerProvider]
/// (Fatia 2) and the order from the pure [RankingTable] (Fatia 1), computed
/// in every build (0 reads when a filter changes).
class RankingScreen extends ConsumerStatefulWidget {
  /// Where the AppBar's "Voltar" leads (the entry that opened the ranking);
  /// null = deep link / reload.
  final String? from;

  const RankingScreen({super.key, this.from});

  @override
  ConsumerState<RankingScreen> createState() => _RankingScreenState();
}

class _RankingScreenState extends ConsumerState<RankingScreen> {
  Timer? _rollover;
  DateTime? _rolloverAt;
  bool _announce = false;
  RankingFilter? _synced;

  @override
  void initState() {
    super.initState();
    // The ranking as the first social screen: confirm the friendships state
    // of the session (docs/97 §4, O11 line 3); a no-op once confirmed.
    Future.microtask(() {
      if (mounted) ref.read(socialControllerProvider.notifier).confirm();
    });
    ref.listenManual(rankingAccessProvider, _onAccess);
  }

  @override
  void dispose() {
    _rollover?.cancel();
    super.dispose();
  }

  /// RF-V3: the last friend is gone. Visible ranking: SnackBar on the root
  /// messenger (it outlives the screen) and out to `/friends` (the redirect
  /// does it; this is the fallback). Stacked under another route: nothing
  /// here; the redirect replaces the stack, so the ranking never shows again.
  void _onAccess(RankingAccess? previous, RankingAccess next) {
    if (next != RankingAccess.noFriends || previous == RankingAccess.noFriends)
      return;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text(RankingTexts.noMoreFriends)));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      if (ref.read(rankingAccessProvider) == RankingAccess.noFriends)
        context.go('/friends');
    });
  }

  /// T2: rewrites a non-canonical address without a history entry and
  /// remembers the filter of the session.
  void _syncAddress(Uri uri, RankingFilter shown) {
    final canonical = RankingFilter.isCanonical(uri, shown);
    if (canonical &&
        _synced == shown &&
        ref.read(rankingLastFilterProvider) == shown)
      return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _synced = shown;
      if (ref.read(rankingLastFilterProvider) != shown) {
        ref.read(rankingLastFilterProvider.notifier).state = shown;
      }
      if (!canonical) _go(shown.location(uri));
    });
  }

  /// `go` (not `push`/`replace`: the address must follow, docs/91 §9) under
  /// [Router.neglect]: no new entry in the browser history; same page key,
  /// so the screen and its controller stay (0 reads).
  void _go(String location) {
    Router.neglect(context, () => context.go(location, extra: widget.from));
  }

  void _setFilter(Uri uri, RankingFilter next) {
    ref.read(rankingLastFilterProvider.notifier).state = next;
    _synced = next;
    _announce = true;
    _go(next.location(uri));
  }

  Future<void> _refresh() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ref.read(rankingControllerProvider.notifier).refresh();
    if (result == RankingRefresh.cooldown) {
      messenger?.showSnackBar(
        const SnackBar(content: Text(kListJustRefreshedMessage)),
      );
    }
  }

  /// §7.3: a rebuild at the next month turn among the zones of the
  /// participants and of the reader (no read).
  void _scheduleRollover(List<RankingParticipant> ps, DateTime now) {
    DateTime next(int tz) {
      final local = now.add(Duration(minutes: tz));
      return DateTime.utc(
        local.year,
        local.month + 1,
      ).subtract(Duration(minutes: tz));
    }

    var at = next(DateTime.now().timeZoneOffset.inMinutes);
    for (final p in ps) {
      final tz = p.tz < -840 || p.tz > 840 ? 0 : p.tz;
      final n = next(tz);
      if (n.isBefore(at)) at = n;
    }
    if (at == _rolloverAt) return;
    _rollover?.cancel();
    _rolloverAt = at;
    final wait = at.difference(now) + const Duration(milliseconds: 1);
    _rollover = Timer(wait.isNegative ? Duration.zero : wait, () {
      if (mounted) setState(() => _rolloverAt = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final inShell = MobileShellScope.active(context);
    final access = ref.watch(rankingAccessProvider);
    final uri = GoRouterState.of(context).uri;
    final filter = RankingFilter.parse(
      uri,
      ref.watch(rankingLastFilterProvider),
    );
    _syncAddress(uri, filter);

    final List<Widget> body;
    if (access != RankingAccess.allowed) {
      // pending (no redirect: skeleton) or on the way out (noFriends...).
      body = [
        _filters(uri, filter, busy: true),
        const SizedBox(height: 16),
        const RankingSkeleton(),
      ];
    } else {
      body = _content(uri, filter, ref.watch(rankingControllerProvider));
    }

    return Scaffold(
      appBar: inShell ? null : _appBar(context),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: kRankingMaxWidth),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (inShell) ...[
                Semantics(
                  header: true,
                  child: Text(
                    RankingTexts.entry,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              ...body,
            ],
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final from = widget.from;
    if (from == null) return detailAppBar(context, title: RankingTexts.entry);
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: 'Voltar',
        onPressed: () => context.go(from),
      ),
      title: const Text(RankingTexts.entry),
    );
  }

  List<Widget> _content(Uri uri, RankingFilter filter, RankingState state) {
    final theme = Theme.of(context);
    final notifier = ref.read(rankingControllerProvider.notifier);
    Widget message(String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: theme.textTheme.bodyLarge),
    );
    Widget retry() => Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: notifier.retry,
        icon: const Icon(Icons.refresh),
        label: const Text(RankingTexts.retry),
      ),
    );

    switch (state.phase) {
      case RankingPhase.offline:
        return [message(RankingTexts.offline)];
      case RankingPhase.error:
        return [message(RankingTexts.loadFailed), retry()];
      case RankingPhase.quota:
        return [message(RankingTexts.quota), retry()];
      case RankingPhase.sessionExpired:
        return [message(RankingTexts.sessionExpired)];
      case RankingPhase.loading:
      case RankingPhase.content:
        break;
    }

    final me = _me(state);
    final participants = [..._friends(state), ?me];
    final now = ref.read(serverClockProvider).now();
    _scheduleRollover(participants, now);

    final loading =
        state.phase == RankingPhase.loading || state.awaitingRecount;
    // RF-E10: until my side is confirmed nothing about me shows (skeleton).
    if (loading || state.meSharing == null) {
      final mine = me == null
          ? null
          : RankingTable.rank([me], filter.metric, filter.period, now);
      return [
        _filters(uri, filter, busy: true),
        const SizedBox(height: 16),
        if (mine != null && state.meSharing == true)
          _row(mine.rows.single, filter, state),
        const RankingSkeleton(),
      ];
    }

    final result = RankingTable.rank(
      participants,
      filter.metric,
      filter.period,
      now,
    );
    final summary = RankingTexts.summaryFor(result, meSharing: state.meSharing);
    if (_announce) {
      _announce = false;
      if (summary != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          SemanticsService.sendAnnouncement(
            View.of(context),
            summary,
            Directionality.of(context),
          );
        });
      }
    }
    final noFriendRows = state.friends.isEmpty;
    final onlyMe = noFriendRows && me != null;
    final nobodyShares = noFriendRows && state.meSharing == false;

    return [
      _filters(uri, filter, busy: state.refreshing),
      const SizedBox(height: 16),
      if (summary != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            summary,
            key: const Key('ranking-summary'),
            style: theme.textTheme.titleMedium,
          ),
        ),
      if (state.meSharing == false) _banner(),
      if (state.failed.isNotEmpty)
        RankingNotice(
          icon: Icons.warning_amber_outlined,
          text: RankingTexts.partialFailure(state.failed.length),
          action: RankingTexts.retry,
          onAction: notifier.retry,
        ),
      if (state.limitedTo != null)
        message(RankingTexts.limited(state.limitedTo!, state.totalFriends)),
      if (result.undatedNote) message(RankingTexts.undatedNote),
      if (nobodyShares) message(RankingTexts.nobodyShares),
      if (result.nobodyScored) message(RankingTexts.nobodyScored),
      for (final row in result.rows) _row(row, filter, state),
      if (onlyMe) message(RankingTexts.onlyMe),
      if (state.notSharing > 0)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            RankingTexts.notSharing(state.notSharing),
            style: theme.textTheme.bodySmall,
          ),
        ),
    ];
  }

  Widget _banner() {
    final review = ref.watch(sharingModeProvider) == SharingMode.review;
    final banner = SharingTexts.rankingBanner(review: review);
    return RankingNotice(
      text: banner.text,
      action: banner.button,
      actionKey: const Key('ranking-banner-action'),
      onAction: () => banner.review
          ? openSharingNotice(context, ref)
          : context.push('/profile'),
    );
  }

  Widget _row(RankingRow row, RankingFilter filter, RankingState state) {
    return RankingRowTile(
      key: ValueKey('ranking-row-${row.who.uid}${row.who.isMe ? '-me' : ''}'),
      row: row,
      metric: filter.metric,
      onOpen: () {
        if (row.who.isMe) {
          context.push('/profile');
          return;
        }
        final friend = state.friends
            .where((f) => f.friend.uid == row.who.uid)
            .firstOrNull
            ?.friend;
        context.push('/friends/u/${row.who.uid}', extra: friend);
      },
    );
  }

  List<RankingParticipant> _friends(RankingState state) => [
    for (final f in state.friends)
      ?RankingParticipant.friend(
        uid: f.friend.uid,
        name: f.friend.name,
        photoUrl: f.friend.photoUrl,
        view: f.view,
      ),
  ];

  /// "Você" from my confirmed document (0 reads), named like the line shows.
  RankingParticipant? _me(RankingState state) {
    final doc = state.me;
    final stats = doc?.stats;
    final uid = ref.watch(currentUidProvider);
    if (state.meSharing != true || doc == null || stats == null || uid == null)
      return null;
    return RankingParticipant.me(
      uid: uid,
      name: ref.watch(displayLabelProvider),
      photoUrl: ref.watch(currentUserProvider)?.photoUrl,
      stats: stats,
      updatedAt: doc.updatedAt,
      tz: doc.tz,
      calc: doc.calc,
    );
  }

  /// Período → Estatística → Atualizar (T3): two dropdowns, one focus each
  /// (Enter/Espaço opens, arrows move, Esc closes without changing).
  Widget _filters(Uri uri, RankingFilter filter, {required bool busy}) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final period = _Dropdown<RankingPeriod>(
      key: const Key('ranking-period'),
      label: RankingTexts.periodLabel,
      value: filter.period,
      values: RankingPeriod.values,
      text: RankingTexts.period,
      onChanged: (p) => _setFilter(uri, filter.copyWith(period: p)),
    );
    final metric = _Dropdown<RankingMetric>(
      key: const Key('ranking-metric'),
      label: RankingTexts.metricLabel,
      value: filter.metric,
      values: RankingMetric.values,
      text: RankingTexts.metric,
      onChanged: (m) => _setFilter(uri, filter.copyWith(metric: m)),
    );
    final refresh = FilledButton.tonalIcon(
      key: const Key('ranking-refresh'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: busy ? null : _refresh,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      label: const Text(RankingTexts.refresh),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= kRankingFiltersRowWidth * scale) {
          return Row(
            children: [
              Expanded(child: period),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: metric),
              const SizedBox(width: 12),
              refresh,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            period,
            const SizedBox(height: 12),
            metric,
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerLeft, child: refresh),
          ],
        );
      },
    );
  }
}

class _Dropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> values;
  final String Function(T) text;
  final ValueChanged<T> onChanged;

  const _Dropdown({
    super.key,
    required this.label,
    required this.value,
    required this.values,
    required this.text,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          items: [
            for (final v in values)
              DropdownMenuItem<T>(
                value: v,
                child: Text(
                  text(v),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) {
            if (v != null && v != value) onChanged(v);
          },
        ),
      ),
    );
  }
}
