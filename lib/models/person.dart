import 'media_type.dart';

/// Public data of a person from TMDB `/person/{id}`. Read-only, never
/// persisted (docs/19).
class PersonProfile {
  final int id;
  final String name;
  final String? profilePath;

  /// Biography text, null when TMDB has none in any language we tried.
  final String? biography;

  /// True when [biography] is the English fallback (pt-BR was empty).
  final bool biographyIsFallback;

  /// Valid dates only; malformed values from TMDB become null.
  final DateTime? birthday;
  final DateTime? deathday;
  final String? placeOfBirth;
  final String? knownForDepartment;

  const PersonProfile({
    required this.id,
    required this.name,
    this.profilePath,
    this.biography,
    this.biographyIsFallback = false,
    this.birthday,
    this.deathday,
    this.placeOfBirth,
    this.knownForDepartment,
  });

  factory PersonProfile.fromTmdb(
    Map<String, dynamic> json, {
    String? fallbackBiography,
  }) {
    final own = _clean(json['biography']);
    final fallback = own == null ? _clean(fallbackBiography) : null;
    return PersonProfile(
      id: json['id'] as int? ?? 0,
      name: _clean(json['name']) ?? '',
      profilePath: _clean(json['profile_path']),
      biography: own ?? fallback,
      biographyIsFallback: fallback != null,
      birthday: parseTmdbDate(json['birthday']),
      deathday: parseTmdbDate(json['deathday']),
      placeOfBirth: _clean(json['place_of_birth']),
      knownForDepartment: _clean(json['known_for_department']),
    );
  }

  /// Age in whole years: at death when there is a death date, otherwise
  /// today. Null without a birth date or when the data is inconsistent
  /// (death before birth, birth in the future).
  int? ageOn(DateTime today) {
    final birth = birthday;
    if (birth == null) return null;
    final end = deathday ?? DateTime(today.year, today.month, today.day);
    if (end.isBefore(birth)) return null;
    var years = end.year - birth.year;
    if (end.month < birth.month || (end.month == birth.month && end.day < birth.day)) years--;
    return years;
  }

  /// Age at death (null when alive or inconsistent).
  int? get ageAtDeath => deathday == null ? null : ageOn(deathday!);
}

/// One acting credit of a person (TMDB `/person/{id}/combined_credits`).
class PersonCredit {
  final int id;
  final MediaType mediaType;
  final String title;
  final String? posterPath;
  final DateTime? date;
  final String? character;
  final double popularity;

  const PersonCredit({
    required this.id,
    required this.mediaType,
    required this.title,
    this.posterPath,
    this.date,
    this.character,
    this.popularity = 0,
  });

  int? get year => date?.year;

  /// Null for adult credits, other media types (e.g. "person") or broken
  /// entries.
  static PersonCredit? fromTmdb(Map<String, dynamic> json) {
    if (json['adult'] == true) return null;
    final type = json['media_type'] is String ? MediaType.fromTmdb(json['media_type']) : null;
    final id = json['id'];
    if (type == null || id is! int) return null;
    final isMovie = type == MediaType.movie;
    return PersonCredit(
      id: id,
      mediaType: type,
      title: _clean(isMovie ? json['title'] : json['name']) ?? '',
      posterPath: _clean(json['poster_path']),
      date: parseTmdbDate(isMovie ? json['release_date'] : json['first_air_date']),
      character: _clean(json['character']),
      popularity: (json['popularity'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Credits grouped for the screen: no repeated title, newest first.
class Filmography {
  final List<PersonCredit> movies;
  final List<PersonCredit> shows;

  const Filmography({this.movies = const [], this.shows = const []});

  bool get isEmpty => movies.isEmpty && shows.isEmpty;

  /// The most popular titles overall ("Conhecido por").
  List<PersonCredit> knownFor({int count = 3}) {
    final all = [...movies, ...shows]..sort((a, b) {
        final byPopularity = b.popularity.compareTo(a.popularity);
        return byPopularity != 0 ? byPopularity : a.id.compareTo(b.id);
      });
    return all.take(count).toList();
  }

  factory Filmography.fromCredits(Iterable<PersonCredit> credits) {
    final byKey = <(MediaType, int), PersonCredit>{};
    for (final c in credits) {
      if (c.title.isEmpty) continue;
      final key = (c.mediaType, c.id);
      final seen = byKey[key];
      if (seen == null) {
        byKey[key] = c;
        continue;
      }
      // Same title twice: one entry, distinct characters joined.
      final roles = <String>[
        ...?seen.character?.split(' / '),
        if (c.character != null && !(seen.character ?? '').split(' / ').contains(c.character))
          c.character!,
      ];
      byKey[key] = PersonCredit(
        id: seen.id,
        mediaType: seen.mediaType,
        title: seen.title,
        posterPath: seen.posterPath ?? c.posterPath,
        date: seen.date ?? c.date,
        character: roles.isEmpty ? null : roles.join(' / '),
        popularity: seen.popularity > c.popularity ? seen.popularity : c.popularity,
      );
    }
    List<PersonCredit> of(MediaType type) => [
          for (final c in byKey.values)
            if (c.mediaType == type) c,
        ]..sort(_byDateDesc);
    return Filmography(movies: of(MediaType.movie), shows: of(MediaType.tv));
  }

  /// Newest first; undated at the end; stable tie-break.
  static int _byDateDesc(PersonCredit a, PersonCredit b) {
    final da = a.date, db = b.date;
    if (da == null && db == null) {
      final byPopularity = b.popularity.compareTo(a.popularity);
      return byPopularity != 0 ? byPopularity : a.id.compareTo(b.id);
    }
    if (da == null) return 1;
    if (db == null) return -1;
    final byDate = db.compareTo(da);
    if (byDate != 0) return byDate;
    final byPopularity = b.popularity.compareTo(a.popularity);
    return byPopularity != 0 ? byPopularity : a.id.compareTo(b.id);
  }
}

/// Strict `yyyy-MM-dd`; anything else (partial, empty, impossible day)
/// is null instead of an exception.
DateTime? parseTmdbDate(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final y = int.parse(value.substring(0, 4));
  final m = int.parse(value.substring(5, 7));
  final d = int.parse(value.substring(8, 10));
  final date = DateTime(y, m, d);
  if (y < 1 || date.year != y || date.month != m || date.day != d) return null;
  return date;
}

/// dd/MM/yyyy
String formatDateBr(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/'
    '${d.year.toString().padLeft(4, '0')}';

String? _clean(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
