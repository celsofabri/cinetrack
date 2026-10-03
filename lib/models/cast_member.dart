/// One person of a title's cast (TMDB `/movie/{id}/credits` or
/// `/tv/{id}/aggregate_credits`). Read-only, never persisted.
class CastMember {
  final int id;
  final String name;

  /// Character(s) played; null when TMDB has none (the card hides the line).
  final String? character;
  final String? profilePath;

  const CastMember({
    required this.id,
    required this.name,
    this.character,
    this.profilePath,
  });

  /// Movie credits: one entry per credit; the same person may repeat.
  static CastMember? fromMovieCredit(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int) return null;
    return CastMember(
      id: id,
      name: _text(json['name']) ?? '',
      character: _text(json['character']),
      profilePath: _text(json['profile_path']),
    );
  }

  /// Aggregate credits (shows): `roles` holds one entry per character; the
  /// first two are kept (docs/19 ❓16).
  static CastMember? fromAggregateCredit(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! int) return null;
    final roles = <String>[
      for (final r in json['roles'] as List? ?? const [])
        if (r is Map && _text(r['character']) != null) _text(r['character'])!,
    ];
    return CastMember(
      id: id,
      name: _text(json['name']) ?? '',
      character: roles.isEmpty ? null : roles.take(2).join(' / '),
      profilePath: _text(json['profile_path']),
    );
  }

  /// Keeps TMDB's order; one entry per person (characters of repeated
  /// entries are joined with " / ").
  static List<CastMember> dedupe(Iterable<CastMember> members) {
    final byId = <int, CastMember>{};
    for (final m in members) {
      final seen = byId[m.id];
      if (seen == null) {
        byId[m.id] = m;
      } else if (m.character != null &&
          !(seen.character ?? '').split(' / ').contains(m.character)) {
        byId[m.id] = CastMember(
          id: seen.id,
          name: seen.name,
          character: seen.character == null ? m.character : '${seen.character} / ${m.character}',
          profilePath: seen.profilePath ?? m.profilePath,
        );
      }
    }
    return [
      for (final m in byId.values)
        if (m.name.isNotEmpty) m,
    ];
  }
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
