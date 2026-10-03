import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/person.dart';
import '../providers/providers.dart';
import '../services/tmdb_exception.dart';
import '../widgets/app_shell.dart';
import '../widgets/error_state.dart';
import '../widgets/poster_image.dart';
import '../widgets/tmdb_attribution.dart';
import 'movie_details_screen.dart' show detailsErrorMessage;
import 'not_found_screen.dart';

/// Initial size of each filmography list; "Mostrar mais" reveals the rest
/// (the list is lazy, so even hundreds of credits stay cheap).
const kFilmographyPageSize = 20;

/// `/person/:id`: profile, biography and filmography of an actor/actress.
/// Lives outside the shell (no tab bar), like the title details: the AppBar
/// with back button and logo is never part of the scrolling content.
class PersonScreen extends ConsumerWidget {
  final int personId;

  const PersonScreen({super.key, required this.personId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(personProvider(personId));
    // Started together with the profile (not after it): the two calls run in
    // parallel; the filmography error stays isolated in its own section.
    ref.watch(personFilmographyProvider(personId));
    final person = profile.valueOrNull;
    final notFound = profile.hasError &&
        profile.error is TmdbException &&
        (profile.error as TmdbException).type == TmdbErrorType.notFound;
    return Scaffold(
      appBar: detailAppBar(context, title: person?.name ?? 'Pessoa'),
      bottomNavigationBar: const DetailBottomBanner(),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => notFound
            ? const NotFoundView(message: 'Pessoa não encontrada')
            : ErrorState(
                message: detailsErrorMessage(error),
                retryLabel: 'Tentar novamente',
                onRetry: () {
                  ref.invalidate(personProvider(personId));
                  ref.invalidate(personFilmographyProvider(personId));
                },
              ),
        data: (p) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: _PersonBody(person: p),
          ),
        ),
      ),
    );
  }
}

class _PersonBody extends ConsumerWidget {
  final PersonProfile person;

  const _PersonBody({required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final credits = ref.watch(personFilmographyProvider(person.id));
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _Header(person: person)),
        SliverToBoxAdapter(child: _Biography(person: person)),
        ...credits.when(
          loading: () => [
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
          ],
          error: (error, _) => [
            SliverToBoxAdapter(
              child: ErrorState(
                message: detailsErrorMessage(error),
                retryLabel: 'Tentar novamente',
                onRetry: () => ref.invalidate(personFilmographyProvider(person.id)),
              ),
            ),
          ],
          data: (film) => film.isEmpty
              ? [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: Text('Nenhum filme ou série encontrado')),
                    ),
                  ),
                ]
              : [
                  SliverToBoxAdapter(child: _KnownFor(credits: film.knownFor())),
                  if (film.movies.isNotEmpty)
                    _CreditsSection(title: 'Filmes', credits: film.movies),
                  if (film.shows.isNotEmpty) _CreditsSection(title: 'Séries', credits: film.shows),
                ],
        ),
        const SliverToBoxAdapter(child: _Attribution()),
      ],
    );
  }
}

String _department(String? raw) => switch (raw) {
      'Acting' => 'Atuação',
      'Directing' => 'Direção',
      'Writing' => 'Roteiro',
      'Production' => 'Produção',
      'Camera' => 'Fotografia',
      'Sound' => 'Som',
      'Editing' => 'Edição',
      'Art' => 'Arte',
      'Crew' => 'Equipe técnica',
      'Costume & Make-Up' => 'Figurino e maquiagem',
      'Visual Effects' => 'Efeitos visuais',
      'Lighting' => 'Iluminação',
      _ => raw ?? '',
    };

String _years(int n) => n == 1 ? '1 ano' : '$n anos';

class _Header extends ConsumerWidget {
  final PersonProfile person;

  const _Header({required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final today = ref.watch(catalogClockProvider)();
    final birth = person.birthday;
    final death = person.deathday;
    final age = person.deathday == null ? person.ageOn(today) : null;
    final ageAtDeath = person.ageAtDeath;
    final department = _department(person.knownForDepartment);
    final lines = <String>[
      if (department.isNotEmpty) department,
      if (birth != null)
        'Nascimento: ${formatDateBr(birth)}${age == null ? '' : ' (${_years(age)})'}',
      if (death != null)
        'Falecimento: ${formatDateBr(death)}${ageAtDeath == null ? '' : ' (${_years(ageAtDeath)})'}',
      if (person.placeOfBirth != null) 'Local de nascimento: ${person.placeOfBirth}',
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: PosterImage(
              posterPath: person.profilePath,
              width: 120,
              height: 180,
              imageSize: 'w185',
              placeholderIcon: Icons.person_outline,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(person.name, style: theme.textTheme.headlineSmall),
                ),
                const SizedBox(height: 8),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(line, style: theme.textTheme.bodyMedium),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Biography extends StatefulWidget {
  final PersonProfile person;

  const _Biography({required this.person});

  @override
  State<_Biography> createState() => _BiographyState();
}

class _BiographyState extends State<_Biography> {
  static const _maxLines = 5;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bio = widget.person.biography;
    final style = theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Biografia', style: theme.textTheme.titleMedium)),
          const SizedBox(height: 8),
          if (bio == null)
            Text('Biografia não disponível', style: style)
          else ...[
            if (widget.person.biographyIsFallback)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Biografia em inglês',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            LayoutBuilder(builder: (context, constraints) {
              final painter = TextPainter(
                text: TextSpan(text: bio, style: style),
                maxLines: _maxLines,
                textDirection: Directionality.of(context),
                textScaler: MediaQuery.textScalerOf(context),
              )..layout(maxWidth: constraints.maxWidth);
              final overflows = painter.didExceedMaxLines;
              painter.dispose();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bio,
                    style: style,
                    maxLines: _expanded ? null : _maxLines,
                    overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                  ),
                  if (overflows)
                    Semantics(
                      button: true,
                      expanded: _expanded,
                      label: _expanded ? 'Mostrar menos' : 'Ler mais',
                      onTap: () => setState(() => _expanded = !_expanded),
                      excludeSemantics: true,
                      child: TextButton(
                        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        child: Text(_expanded ? 'Mostrar menos' : 'Ler mais'),
                      ),
                    ),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }
}

void _openTitle(BuildContext context, PersonCredit credit) =>
    context.push('/${credit.mediaType.jsonValue}/${credit.id}');

String _creditLabel(PersonCredit c) => [
      c.title,
      if (c.year != null) '${c.year}',
      if (c.character != null) c.character!,
    ].join(', ');

class _KnownFor extends StatelessWidget {
  final List<PersonCredit> credits;

  const _KnownFor({required this.credits});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text('Conhecido por', style: theme.textTheme.titleMedium)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in credits)
                SizedBox(
                  width: 88,
                  child: Semantics(
                    button: true,
                    label: c.title,
                    onTap: () => _openTitle(context, c),
                    excludeSemantics: true,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _openTitle(context, c),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PosterImage(posterPath: c.posterPath, width: 88, height: 132),
                          const SizedBox(height: 4),
                          Text(c.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreditsSection extends StatefulWidget {
  final String title;
  final List<PersonCredit> credits;

  const _CreditsSection({required this.title, required this.credits});

  @override
  State<_CreditsSection> createState() => _CreditsSectionState();
}

class _CreditsSectionState extends State<_CreditsSection> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.credits.length;
    final count = _all ? total : (total < kFilmographyPageSize ? total : kFilmographyPageSize);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Semantics(
              header: true,
              child:
                  Text('${widget.title} ($total)', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: count,
          itemBuilder: (_, i) => _CreditTile(credit: widget.credits[i]),
        ),
        if (count < total)
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => setState(() => _all = true),
                  child: Text('Mostrar mais (${total - count})'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CreditTile extends StatelessWidget {
  final PersonCredit credit;

  const _CreditTile({required this.credit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Semantics(
      button: true,
      label: _creditLabel(credit),
      onTap: () => _openTitle(context, credit),
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _openTitle(context, credit),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PosterImage(posterPath: credit.posterPath, width: 56, height: 84),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(credit.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge),
                    if (credit.year != null) Text('${credit.year}', style: muted),
                    if (credit.character != null)
                      Text(credit.character!,
                          maxLines: 2, overflow: TextOverflow.ellipsis, style: muted),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Attribution extends StatelessWidget {
  const _Attribution();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(16, 32, 16, 24),
        child: TmdbAttribution(),
      );
}
