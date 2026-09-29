enum TmdbErrorType {
  network,
  unauthorized,
  rateLimited,
  notFound,
  unknown,
}

class TmdbException implements Exception {
  final TmdbErrorType type;
  final String message;

  const TmdbException(this.type, this.message);

  factory TmdbException.network() =>
      const TmdbException(TmdbErrorType.network, 'Sem conexão com a internet.');

  factory TmdbException.unauthorized() => const TmdbException(
        TmdbErrorType.unauthorized,
        'Chave de API do TMDB ausente ou inválida. Configure TMDB_API_KEY no .env.',
      );

  factory TmdbException.rateLimited() => const TmdbException(
        TmdbErrorType.rateLimited,
        'Muitas requisições ao TMDB agora. Tente novamente em instantes.',
      );

  factory TmdbException.notFound() =>
      const TmdbException(TmdbErrorType.notFound, 'Conteúdo não encontrado no TMDB.');

  factory TmdbException.fromStatusCode(int statusCode) => switch (statusCode) {
        401 => TmdbException.unauthorized(),
        404 => TmdbException.notFound(),
        429 => TmdbException.rateLimited(),
        _ => TmdbException(
            TmdbErrorType.unknown,
            'Erro inesperado ao falar com o TMDB (HTTP $statusCode).',
          ),
      };

  @override
  String toString() => message;
}
