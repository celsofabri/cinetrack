/// Periods of the shared statistics (docs/82 §5.1, B1): month and year in the
/// OWNER's time zone at calculation time, so every reader (whatever their own
/// zone) sees the same "this month" for a friend.
typedef PeriodKeys = ({String month, String year});

/// Smallest / largest UTC offset accepted by the rules (`tz`, minutes).
const kMinTzMinutes = -840;
const kMaxTzMinutes = 840;

/// `(month: "YYYY-MM", year: "YYYY")` of [instant] seen at UTC offset
/// [tzMinutes]. Pure: depends only on its arguments.
PeriodKeys periodKey(DateTime instant, int tzMinutes) {
  final local = instant.toUtc().add(Duration(minutes: tzMinutes));
  final year = local.year.toString().padLeft(4, '0');
  return (month: '$year-${local.month.toString().padLeft(2, '0')}', year: year);
}

/// A UTC offset in minutes as the rules accept it: an int in
/// [kMinTzMinutes]..[kMaxTzMinutes]. Normalizes `-0` to `0` (on the web a
/// Dart int is a JS number: `-0` would be written as a double and the rule
/// `tz is int` would refuse it).
int normalizeTz(num minutes) {
  if (minutes == 0 || minutes.isNaN) return 0;
  final rounded = minutes.round();
  if (rounded == 0) return 0;
  return rounded.clamp(kMinTzMinutes, kMaxTzMinutes);
}

/// The device's offset at [now] (owner side), normalized.
int deviceTzMinutes(DateTime now) => normalizeTz(now.timeZoneOffset.inMinutes);
