/// A "by category" carousel definition. Unifies movie and TV genre
/// browsing under one label even though TMDB uses separate genre
/// taxonomies for each media type — `tvGenreId` is null when TV has no
/// equivalent genre (e.g. Horror, Romance don't exist as TV genres on
/// TMDB), in which case the category only queries `/discover/movie`.
/// See docs/06-design-home-descoberta.md, decision 3.
typedef DiscoveryCategory = ({String label, int movieGenreId, int? tvGenreId});

const kDiscoveryCategories = <DiscoveryCategory>[
  (label: 'Ação', movieGenreId: 28, tvGenreId: 10759), // TV: Action & Adventure
  (label: 'Comédia', movieGenreId: 35, tvGenreId: 35),
  (label: 'Terror', movieGenreId: 27, tvGenreId: null), // TV has no horror genre
  (label: 'Romance', movieGenreId: 10749, tvGenreId: null), // TV has no romance genre
  (label: 'Animação', movieGenreId: 16, tvGenreId: 16),
];
