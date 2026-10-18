/// Largest integer a JS number holds exactly (2^53 - 1).
const kMaxSafeInt = 9007199254740991;

/// The whole number [v] when it lies in [min]..[max], else null (unknown).
///
/// One reader for every number another user wrote (docs/91 §5.2, hotfix
/// A2). On the web (dart2js) every integral JS number "is int", including
/// `Infinity` and `1e300`, hence the explicit bounds; on the VM a Firestore
/// doubleValue such as `12.0` is a double, hence whole doubles are accepted,
/// so both platforms read the same values. NaN, infinities, fractions and anything
/// outside the range are null; never throws.
///
/// The bounds come first and are always finite: they reject +-Infinity (on
/// the web those "are" int and would skip the fraction test) and keep
/// `toInt` away from values it cannot represent. NaN fails the fraction
/// test (NaN != NaN).
int? readSafeInt(Object? v, {int min = 0, int max = kMaxSafeInt}) {
  if (v is! num || v < min || v > max) return null;
  if (v is! int && v != v.truncateToDouble()) return null; // 12.5, NaN
  // On the web `-0.0` "is int"; dart2js `toInt` (`| 0`) already yields 0.
  return v.toInt();
}
