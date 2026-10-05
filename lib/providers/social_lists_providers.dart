import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/social_repository.dart';
import '../social/social_models.dart';
import 'providers.dart';
import 'social_providers.dart';

/// Lists of slice 3 (docs/62): received requests, friends and the number on
/// the badge. Same rules as the "Enviados" list of slice 2: nothing is read
/// until a screen asks, no listener, the first page is kept for a TTL, every
/// write is confirmed by the server, and everything in memory belongs to ONE
/// account and ONE "friendships on" period.

typedef ListPhase = SentPhase;

/// The clock the lists and the badge use (tests inject their own).
final socialClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// A manual "Atualizar" within this time of the last read does nothing (the
/// list on screen is already that fresh): keeps the quota safe from a mashed button.
final refreshCooldownProvider = Provider<Duration>((ref) => const Duration(seconds: 15));

class PagedState<T> {
  final ListPhase phase;
  final List<T> items;
  final bool hasMore;
  final Object? cursor;

  /// The list shown came from this device, not from the server.
  final bool fromCache;
  final bool loadingMore;

  /// A "Ver mais" that failed (the page already shown stays).
  final SocialFailure? moreFailure;

  /// Why the first page failed (phase [SentPhase.error]).
  final SocialFailure? failure;

  /// Keys (uids) whose action is running right now.
  final Set<String> busy;

  /// When the first page was read from the server (null = never / from cache).
  final DateTime? loadedAt;

  const PagedState({
    this.phase = SentPhase.idle,
    this.items = const [],
    this.hasMore = false,
    this.cursor,
    this.fromCache = false,
    this.loadingMore = false,
    this.moreFailure,
    this.failure,
    this.busy = const {},
    this.loadedAt,
  });

  PagedState<T> copyWith({
    ListPhase? phase,
    List<T>? items,
    bool? hasMore,
    Object? cursor,
    bool? fromCache,
    bool? loadingMore,
    SocialFailure? moreFailure,
    bool clearMoreFailure = false,
    Set<String>? busy,
    DateTime? loadedAt,
  }) => PagedState<T>(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    hasMore: hasMore ?? this.hasMore,
    cursor: cursor ?? this.cursor,
    fromCache: fromCache ?? this.fromCache,
    loadingMore: loadingMore ?? this.loadingMore,
    moreFailure: clearMoreFailure ? null : (moreFailure ?? this.moreFailure),
    failure: failure,
    busy: busy ?? this.busy,
    loadedAt: loadedAt ?? this.loadedAt,
  );
}

/// One page of a [PagedListController].
class PageData<T> {
  final List<T> items;
  final Object? cursor;
  final bool hasMore;
  final bool fromCache;

  const PageData(this.items, this.cursor, this.hasMore, this.fromCache);
}

/// Shared behaviour of the received-requests and friends lists.
abstract class PagedListController<T> extends Notifier<PagedState<T>> {
  int _generation = 0;

  int get pageSize;

  /// Most items ever listed (null = no cap). The rest waits until the user
  /// answers some (docs/49 D5).
  int? get maxItems => null;

  String keyOf(T item);
  Future<PageData<T>> fetch(Object? cursor, int limit);

  /// Items in display order.
  List<T> arrange(List<T> items) => items;

  /// Called when the first page arrived from the server.
  void onFirstPage(PagedState<T> loaded) {}

  /// Called for every state-dependent rebuild trigger (subclasses watch).
  void watchScope();

  @override
  PagedState<T> build() {
    _generation++;
    ref.watch(currentUidProvider);
    // Turning friendships off deletes these documents on the server, and a
    // different account must not see this list: rebuild empty.
    ref.watch(socialPeriodProvider);
    watchScope();
    return PagedState<T>();
  }

  bool get _expired {
    final at = state.loadedAt;
    return at == null ||
        ref.read(socialClockProvider)().difference(at) >= ref.read(sentRequestsTtlProvider);
  }

  /// True while the list in memory can still be shown without a read.
  bool get isFresh => state.phase == SentPhase.loaded && !_expired;

  Future<void> ensureLoaded() async {
    if (ref.read(currentUidProvider) == null) return;
    if (state.phase == SentPhase.loading) return;
    if (isFresh) return;
    await _loadFirst();
  }

  /// The "Atualizar" button: a read, unless the list was read a moment ago.
  Future<void> refresh() async {
    final at = state.loadedAt;
    if (at != null &&
        state.phase == SentPhase.loaded &&
        ref.read(socialClockProvider)().difference(at) < ref.read(refreshCooldownProvider)) {
      return;
    }
    await reload();
  }

  Future<void> reload() async {
    if (ref.read(currentUidProvider) == null || state.phase == SentPhase.loading) return;
    await _loadFirst();
  }

  int _limitFor(int loaded) {
    final cap = maxItems;
    return cap == null ? pageSize : (cap - loaded).clamp(1, pageSize);
  }

  Future<void> _loadFirst() async {
    final generation = _generation;
    state = state.phase == SentPhase.loaded
        ? state.copyWith(clearMoreFailure: true)
        : PagedState<T>(phase: SentPhase.loading);
    try {
      final page = await fetch(null, _limitFor(0));
      if (generation != _generation) return;
      final cap = maxItems;
      state = PagedState<T>(
        phase: SentPhase.loaded,
        items: arrange(page.items),
        hasMore: page.hasMore && (cap == null || page.items.length < cap),
        cursor: page.cursor,
        fromCache: page.fromCache,
        loadedAt: page.fromCache ? null : ref.read(socialClockProvider)(),
      );
      if (!page.fromCache) onFirstPage(state);
    } on SocialFailure catch (e) {
      if (generation != _generation) return;
      state = state.phase == SentPhase.loaded
          ? state.copyWith(moreFailure: e)
          : PagedState<T>(phase: SentPhase.error, failure: e);
    } catch (_) {
      if (generation != _generation) return;
      state = PagedState<T>(
        phase: SentPhase.error,
        failure: const SocialFailure(SocialFailureKind.unknown),
      );
    }
  }

  Future<void> loadMore() async {
    if (state.phase != SentPhase.loaded || !state.hasMore || state.loadingMore) return;
    final generation = _generation;
    state = state.copyWith(loadingMore: true, clearMoreFailure: true);
    try {
      final page = await fetch(state.cursor, _limitFor(state.items.length));
      if (generation != _generation) return;
      final known = {for (final r in state.items) keyOf(r)};
      // Pages already on screen never move: the new page is ordered on its own
      // and appended at the end (docs/62).
      final items = [
        ...state.items,
        ...arrange([
          for (final r in page.items)
            if (!known.contains(keyOf(r))) r,
        ]),
      ];
      final cap = maxItems;
      state = state.copyWith(
        items: items,
        hasMore: page.hasMore && (cap == null || items.length < cap),
        cursor: page.cursor,
        fromCache: state.fromCache || page.fromCache,
        loadingMore: false,
      );
    } on SocialFailure catch (e) {
      if (generation == _generation) state = state.copyWith(loadingMore: false, moreFailure: e);
    } catch (_) {
      if (generation == _generation) {
        state = state.copyWith(
          loadingMore: false,
          moreFailure: const SocialFailure(SocialFailureKind.unknown),
        );
      }
    }
  }

  /// Runs [action] for [key] (shows "salvando..."), then removes the item on
  /// success. Returns the failure to show, or null. An unconfirmed write may
  /// or may not have happened: the list is read again then.
  Future<SocialFailure?> runFor(
    String key,
    Future<void> Function() action, {
    bool removeOnSuccess = true,
    bool Function(SocialFailureKind kind) removeOnKinds = _never,
  }) async {
    if (state.busy.contains(key)) return null;
    final generation = _generation;
    state = state.copyWith(busy: {...state.busy, key});
    SocialFailure? failure;
    try {
      await action();
    } on SocialFailure catch (e) {
      failure = e;
    } catch (_) {
      failure = const SocialFailure(SocialFailureKind.unknown);
    }
    if (generation != _generation) return failure;
    final left = {...state.busy}..remove(key);
    final remove = failure == null ? removeOnSuccess : removeOnKinds(failure.kind);
    state = state.copyWith(
      busy: left,
      items: remove
          ? [
              for (final r in state.items)
                if (keyOf(r) != key) r,
            ]
          : null,
    );
    if (failure?.kind == SocialFailureKind.uncertain) await reload();
    return failure;
  }

  static bool _never(SocialFailureKind kind) => false;
}

/// Pending requests other people sent to this user ("Recebidos").
class ReceivedRequestsController extends PagedListController<ReceivedRequest> {
  @override
  int get pageSize => kReceivedPageSize;

  @override
  int? get maxItems => kMaxReceivedListed;

  @override
  String keyOf(ReceivedRequest item) => item.fromUid;

  @override
  void watchScope() {}

  @override
  Future<PageData<ReceivedRequest>> fetch(Object? cursor, int limit) async {
    final page = await ref
        .read(socialRepositoryProvider)
        .receivedRequests(cursor: cursor, pageSize: limit);
    return PageData(page.items, page.cursor, page.hasMore, page.fromCache);
  }

  @override
  void onFirstPage(PagedState<ReceivedRequest> loaded) {
    // The list is the best count there is (no extra read).
    ref
        .read(receivedCountControllerProvider.notifier)
        .fromList(loaded.items.length, complete: !loaded.hasMore);
  }

  /// Accepts [request]: friendship + request consumed in ONE batch. Returns
  /// the failure to show, or null. On "not accepted" the request is probably
  /// gone, so it leaves the list too.
  Future<SocialFailure?> accept(ReceivedRequest request) async {
    final me = ref.read(socialControllerProvider).profile;
    if (me == null) return const SocialFailure(SocialFailureKind.notActive);
    final repository = ref.read(socialRepositoryProvider);
    final failure = await runFor(
      request.fromUid,
      () => repository.acceptRequest(request, me: me),
      removeOnKinds: (kind) => kind == SocialFailureKind.notAccepted,
    );
    if (failure == null) {
      ref.read(receivedCountControllerProvider.notifier).adjust(-1);
      ref.read(friendsControllerProvider.notifier).add(request.asFriend());
    } else if (failure.kind == SocialFailureKind.notAccepted) {
      ref.read(receivedCountControllerProvider.notifier).adjust(-1);
    }
    return failure;
  }

  /// Declines [request]: one silent delete.
  Future<SocialFailure?> decline(ReceivedRequest request) async {
    final repository = ref.read(socialRepositoryProvider);
    final failure = await runFor(request.fromUid, () => repository.declineRequest(request.fromUid));
    if (failure == null) ref.read(receivedCountControllerProvider.notifier).adjust(-1);
    return failure;
  }

  /// A crossed request became a friendship: their request is gone.
  void consumed(String fromUid) {
    final before = state.items.length;
    final items = [
      for (final r in state.items)
        if (r.fromUid != fromUid) r,
    ];
    if (items.length != before) {
      state = state.copyWith(items: items);
      ref.read(receivedCountControllerProvider.notifier).adjust(-1);
    } else if (state.phase != SentPhase.loaded) {
      // Not loaded: the count may still include it.
      ref.read(receivedCountControllerProvider.notifier).adjust(-1);
    }
  }
}

extension on ReceivedRequest {
  Friend asFriend() =>
      Friend(uid: fromUid, name: fromName, photoUrl: fromPhoto, since: DateTime.now());
}

final receivedRequestsControllerProvider =
    NotifierProvider<ReceivedRequestsController, PagedState<ReceivedRequest>>(
      ReceivedRequestsController.new,
    );

/// pt-BR friendly sort key: lower case, accents folded ("Álvaro" sorts with
/// the As, before "Zé"), so a plain `compareTo` gives the order a person expects.
String collationKey(String name) {
  const from = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿ';
  const to = 'aaaaaaceeeeiiiinooooouuuuyy';
  final buffer = StringBuffer();
  for (final rune in name.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    final i = from.indexOf(ch);
    buffer.write(i < 0 ? ch : to[i]);
  }
  return buffer.toString();
}

/// The friends ("Amigos"), sorted by name.
class FriendsController extends PagedListController<Friend> {
  @override
  int get pageSize => kFriendsPageSize;

  @override
  String keyOf(Friend item) => item.uid;

  @override
  void watchScope() {}

  @override
  List<Friend> arrange(List<Friend> items) => [...items]
    ..sort((a, b) {
      final byName = collationKey(a.name).compareTo(collationKey(b.name));
      return byName != 0 ? byName : a.uid.compareTo(b.uid);
    });

  @override
  Future<PageData<Friend>> fetch(Object? cursor, int limit) async {
    final page = await ref.read(socialRepositoryProvider).friends(cursor: cursor, pageSize: limit);
    return PageData(page.items, page.cursor, page.hasMore, page.fromCache);
  }

  bool contains(String uid) => state.items.any((f) => f.uid == uid);

  /// A friendship just created by this device: shown without a read.
  void add(Friend friend) {
    if (state.phase != SentPhase.loaded || contains(friend.uid)) return;
    // One new friend slots in by name among those shown; nothing else moves.
    final items = [...state.items];
    var at = items.indexWhere((f) => collationKey(f.name).compareTo(collationKey(friend.name)) > 0);
    if (at < 0) at = items.length;
    items.insert(at, friend);
    state = state.copyWith(items: items);
  }

  /// Removes the friendship (both sides lose it; nobody is told).
  Future<SocialFailure?> remove(Friend friend) {
    final repository = ref.read(socialRepositoryProvider);
    return runFor(friend.uid, () => repository.removeFriend(friend.uid));
  }
}

final friendsControllerProvider = NotifierProvider<FriendsController, PagedState<Friend>>(
  FriendsController.new,
);

/// How long the badge number is trusted before the next screen that shows it
/// asks again (one `count()` read). Tests override.
final receivedCountTtlProvider = Provider<Duration>((ref) => const Duration(minutes: 10));

class ReceivedCountState {
  /// Null = not known (no badge).
  final int? count;
  final DateTime? loadedAt;
  final bool loading;

  const ReceivedCountState({this.count, this.loadedAt, this.loading = false});
}

/// The number on the Amigos badge. One aggregate `count()` (a single billed
/// read, capped at [kMaxReceivedListed]) per [receivedCountTtlProvider] and
/// only when a screen shows the badge; opening the received list refreshes it
/// for free; accepting / declining adjust it locally. Never a listener.
class ReceivedCountController extends Notifier<ReceivedCountState> {
  int _generation = 0;

  @override
  ReceivedCountState build() {
    _generation++;
    ref.watch(currentUidProvider);
    ref.watch(socialPeriodProvider);
    return const ReceivedCountState();
  }

  Future<void> ensureFresh() async {
    if (ref.read(currentUidProvider) == null || state.loading) return;
    if (!ref.read(socialActiveProvider)) return; // never for accounts without friendships
    final at = state.loadedAt;
    final now = ref.read(socialClockProvider);
    if (at != null && now().difference(at) < ref.read(receivedCountTtlProvider)) return;
    final generation = _generation;
    state = ReceivedCountState(count: state.count, loadedAt: state.loadedAt, loading: true);
    try {
      final count = await ref.read(socialRepositoryProvider).receivedCount();
      if (generation != _generation) return;
      state = ReceivedCountState(count: count, loadedAt: now());
    } catch (_) {
      // Offline / denied: no badge (never an error on the top bar). Try again
      // after the TTL.
      if (generation != _generation) return;
      state = ReceivedCountState(count: state.count, loadedAt: now());
    }
  }

  /// The list was just read from the server.
  void fromList(int shown, {required bool complete}) {
    final known = state.count ?? 0;
    state = ReceivedCountState(
      count: complete ? shown : (shown > known ? shown : known),
      loadedAt: ref.read(socialClockProvider)(),
    );
  }

  void adjust(int delta) {
    final current = state.count;
    if (current == null) return;
    state = ReceivedCountState(
      count: (current + delta).clamp(0, kMaxReceivedListed),
      loadedAt: state.loadedAt,
    );
  }
}

final receivedCountControllerProvider =
    NotifierProvider<ReceivedCountController, ReceivedCountState>(ReceivedCountController.new);

/// The number for the badge (0 = none): only for accounts with friendships on.
/// Pure: whoever SHOWS the badge calls [refreshBadge] so the count is asked at
/// most once per TTL (a provider alone would only run again when the number
/// itself changes, i.e. never).
final receivedBadgeProvider = Provider<int>((ref) {
  if (!ref.watch(socialActiveProvider)) return 0;
  return ref.watch(receivedCountControllerProvider.select((s) => s.count)) ?? 0;
});

/// Asks for the count if it is older than the TTL (no-op otherwise, and for
/// accounts without friendships). Call from the `build` of a widget that shows
/// the badge, when `/friends` opens, and when the app comes back to the front.
void refreshBadge(WidgetRef ref) {
  // After the frame: providers that changed upstream have been rebuilt by the
  // widgets that watch them, so reading here never builds one mid-flush.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      if (!ref.context.mounted) return;
      ref.read(receivedCountControllerProvider.notifier).ensureFresh();
    } catch (_) {}
  });
  WidgetsBinding.instance.ensureVisualUpdate();
}

/// Keeps the badge honest without a listener: refreshes (within the TTL) on
/// every navigation inside the shell and when the app returns to the front.
class BadgeRefresher extends ConsumerStatefulWidget {
  final Widget child;

  const BadgeRefresher({super.key, required this.child});

  @override
  ConsumerState<BadgeRefresher> createState() => _BadgeRefresherState();
}

class _BadgeRefresherState extends ConsumerState<BadgeRefresher> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshBadge(ref);
  }

  @override
  void didUpdateWidget(BadgeRefresher old) {
    super.didUpdateWidget(old);
    refreshBadge(ref); // the shell builds again on every navigation
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
