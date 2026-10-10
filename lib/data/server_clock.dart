/// The device clock corrected by an estimate of the server's offset
/// (docs/82 §4.2, A5): the date of an episode mark is ONE instant per write,
/// taken from here, never a `serverTimestamp` per episode (a whole series can
/// carry up to 5000 episodes; Firestore documents at most 500 transforms per
/// document in one write).
///
/// The offset is learned from the user's own writes: `lastWatchedAt` goes out
/// as `serverTimestamp()` and the [ActivityOverlay] keeps the local time of
/// the mark; when the server confirms it, `offset = server - local`. Without
/// a sample the offset is zero (the device clock).
class ServerClock {
  final DateTime Function() _deviceNow;
  Duration _offset = Duration.zero;
  bool _sampled = false;

  /// A confirmation that arrives later than this after the mark (monotonic
  /// time) is not used: it may be another device's write, or a write that
  /// sat in the offline queue.
  static const maxRoundTrip = Duration(seconds: 60);

  /// Offsets beyond this are not believed (a broken sample, not a clock).
  static const maxOffset = Duration(days: 2);

  ServerClock({DateTime Function()? deviceNow}) : _deviceNow = deviceNow ?? DateTime.now;

  /// Server time as best known now (UTC).
  DateTime now() => _deviceNow().toUtc().add(_offset);

  Duration get offset => _offset;

  /// At least one sample was accepted in this session.
  bool get sampled => _sampled;

  /// The server confirmed [server] for a write stamped locally at [local],
  /// [elapsed] (monotonic) after it was sent. Returns whether it was used.
  bool sample({required DateTime local, required DateTime server, required Duration elapsed}) {
    if (elapsed.isNegative || elapsed > maxRoundTrip) return false;
    final offset = server.toUtc().difference(local.toUtc());
    if (offset.abs() > maxOffset) return false;
    _offset = offset;
    _sampled = true;
    return true;
  }
}
