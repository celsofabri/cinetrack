import 'ranking_models.dart';

/// The ranking's filter in the address (docs/90 T2, D3, D15). Pure.
///
/// Canonical form: `/ranking?estatistica=<slug>&periodo=<slug>` followed by
/// any other parameter of the original address, untouched and in its order.
class RankingFilter {
  final RankingMetric metric;
  final RankingPeriod period;

  const RankingFilter(this.metric, this.period);

  /// D3: Episódios assistidos · Este ano.
  static const standard = RankingFilter(
    RankingMetric.episodes,
    RankingPeriod.year,
  );

  static const metricKey = 'estatistica';
  static const periodKey = 'periodo';
  static const path = '/ranking';

  RankingFilter copyWith({RankingMetric? metric, RankingPeriod? period}) =>
      RankingFilter(metric ?? this.metric, period ?? this.period);

  /// The filter shown for [uri]: per exact key (`estatistica`, `periodo`),
  /// the FIRST occurrence, value without case; absent or invalid falls back
  /// to [last] (the last filter of the session), then to [standard].
  static RankingFilter parse(Uri uri, RankingFilter? last) {
    final fallback = last ?? standard;
    final all = _pairs(uri.query);
    String? first(String key) {
      for (final (k, v, _) in all) {
        if (k == key) return v.toLowerCase();
      }
      return null;
    }

    final m = first(metricKey);
    final p = first(periodKey);
    return RankingFilter(
      RankingMetric.values.where((e) => e.slug == m).firstOrNull ??
          fallback.metric,
      RankingPeriod.values.where((e) => e.slug == p).firstOrNull ??
          fallback.period,
    );
  }

  /// The canonical location of this filter keeping the other parameters of
  /// [uri] (raw, in their order); every occurrence of the two keys is
  /// replaced by one canonical pair at the start.
  String location([Uri? uri]) {
    final others = [
      for (final (k, _, raw) in _pairs(uri?.query ?? ''))
        if (k != metricKey && k != periodKey) raw,
    ];
    return [
      '$path?$metricKey=${metric.slug}&$periodKey=${period.slug}',
      ...others,
    ].join('&');
  }

  /// Whether [uri] already is the canonical address of what it shows.
  static bool isCanonical(Uri uri, RankingFilter shown) =>
      _asLocation(uri) == shown.location(uri);

  static String _asLocation(Uri uri) =>
      uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}';

  /// (decoded key, decoded value, raw piece) of each non-empty piece.
  static List<(String, String, String)> _pairs(String query) {
    final out = <(String, String, String)>[];
    for (final raw in query.split('&')) {
      if (raw.isEmpty) continue;
      final eq = raw.indexOf('=');
      final k = eq < 0 ? raw : raw.substring(0, eq);
      final v = eq < 0 ? '' : raw.substring(eq + 1);
      out.add((_decode(k), _decode(v), raw));
    }
    return out;
  }

  static String _decode(String s) {
    try {
      return Uri.decodeQueryComponent(s);
    } catch (_) {
      return s; // malformed escape: compared as typed
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RankingFilter &&
      other.metric == metric &&
      other.period == period;

  @override
  int get hashCode => Object.hash(metric, period);

  @override
  String toString() => 'RankingFilter(${metric.slug}, ${period.slug})';
}
