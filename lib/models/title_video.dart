/// A video of a title as listed by TMDB (`/movie/{id}/videos`,
/// `/tv/{id}/videos`). Only the fields the trailer choice needs.
class TitleVideo {
  /// YouTube video id (`key` of TMDB). Always validated by [fromTmdb], since it
  /// ends up in a URL.
  final String key;
  final String name;
  final String type;
  final bool official;

  /// ISO 639-1 language of the video ('pt', 'en'), null when TMDB has none.
  final String? language;
  final int size;
  final DateTime? publishedAt;

  const TitleVideo({
    required this.key,
    required this.name,
    required this.type,
    required this.official,
    this.language,
    this.size = 0,
    this.publishedAt,
  });

  static final _youtubeId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// Whether [key] is a well-formed YouTube id (checked again wherever a URL
  /// is built, not only when parsing).
  static bool isValidKey(String key) => _youtubeId.hasMatch(key);

  /// Null for anything that is not a usable YouTube video (other sites, missing
  /// or malformed key): they are discarded at the edge.
  static TitleVideo? fromTmdb(Map<String, dynamic> json) {
    final key = json['key'];
    if (json['site'] != 'YouTube' || key is! String || !isValidKey(key)) return null;
    final published = json['published_at'];
    return TitleVideo(
      key: key,
      name: json['name'] as String? ?? '',
      type: json['type'] as String? ?? '',
      official: json['official'] == true,
      language: json['iso_639_1'] as String?,
      size: json['size'] as int? ?? 0,
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    );
  }

  /// Embed URL on the privacy-enhanced domain. No user data goes in it.
  Uri get embedUri => _checked(
    () => Uri.https('www.youtube-nocookie.com', '/embed/$key', {
      'autoplay': '1',
      'rel': '0',
      'playsinline': '1',
      'hl': 'pt-BR',
    }),
  );

  /// Where the video lives on YouTube (the universal fallback).
  Uri get watchUri => _checked(() => Uri.https('www.youtube.com', '/watch', {'v': key}));

  Uri _checked(Uri Function() build) {
    if (!isValidKey(key)) throw ArgumentError.value(key, 'key', 'not a YouTube video id');
    return build();
  }
}

/// Chooses the one trailer to show (docs/45): YouTube only; "Trailer" over
/// "Teaser"; official over not; Portuguese over English over no language;
/// then the larger and the newer video. Everything else is discarded.
class TrailerPicker {
  const TrailerPicker._();

  static TitleVideo? best(Iterable<TitleVideo> videos) {
    TitleVideo? best;
    var bestScore = -1;
    for (final v in videos) {
      final score = _score(v);
      if (score < 0) continue;
      if (best == null || score > bestScore || (score == bestScore && _newer(v, best))) {
        best = v;
        bestScore = score;
      }
    }
    return best;
  }

  static int _score(TitleVideo v) {
    final type = switch (v.type) {
      'Trailer' => 1000,
      'Teaser' => 500,
      _ => -1,
    };
    if (type < 0 || !TitleVideo.isValidKey(v.key)) return -1;
    final language = switch (v.language) {
      'pt' => 60,
      'en' => 30,
      null || '' => 10,
      _ => -1, // another language without subtitles: not useful here
    };
    if (language < 0) return -1;
    final quality = v.size >= 1080 ? 5 : (v.size >= 720 ? 2 : 0);
    return type + (v.official ? 100 : 0) + language + quality;
  }

  static bool _newer(TitleVideo a, TitleVideo b) {
    final pa = a.publishedAt;
    final pb = b.publishedAt;
    return pa != null && (pb == null || pa.isAfter(pb));
  }
}
