import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/cast_member.dart';
import '../providers/providers.dart';
import '../screens/movie_details_screen.dart' show detailsErrorMessage;
import 'poster_image.dart';

/// People shown in the carousel of the details screens; "Ver todos" opens the
/// full list (docs/19 ❓1, Manager decision 3).
const kCastCarouselLimit = 15;

String castPath(TitleKey key) => '/${key.type.jsonValue}/${key.id}/cast';

/// Round profile photo (decorative: the name is announced by the parent).
class ProfileAvatar extends StatelessWidget {
  final String? path;
  final double size;

  const ProfileAvatar({super.key, required this.path, required this.size});

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ClipOval(
        child: PosterImage(
          posterPath: path,
          width: size,
          height: size,
          imageSize: 'w185',
          placeholderIcon: Icons.person_outline,
        ),
      ),
    );
  }
}

String castSemanticsLabel(CastMember m) =>
    m.character == null ? m.name : '${m.name}, ${m.character}';

/// Card of the horizontal carousel: photo, name, character. One semantic
/// button; the whole card is the touch target (well over 48 px).
class CastCard extends StatelessWidget {
  final CastMember member;
  static const width = 104.0;

  const CastCard({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open() => context.push('/person/${member.id}');
    return SizedBox(
      width: width,
      child: Semantics(
        button: true,
        label: castSemanticsLabel(member),
        onTap: open,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              children: [
                ProfileAvatar(path: member.profilePath, size: 72),
                const SizedBox(height: 8),
                Text(
                  member.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (member.character != null)
                  Text(
                    member.character!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Row of the full cast list.
class CastRow extends StatelessWidget {
  final CastMember member;

  const CastRow({super.key, required this.member});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    void open() => context.push('/person/${member.id}');
    return Semantics(
      button: true,
      label: castSemanticsLabel(member),
      onTap: open,
      excludeSemantics: true,
      child: InkWell(
        onTap: open,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                ProfileAvatar(path: member.profilePath, size: 48),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(member.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge),
                      if (member.character != null)
                        Text(member.character!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Elenco" block of the movie/show details. Loading, error and empty are
/// handled here, so a cast failure never touches the rest of the screen.
class CastSection extends ConsumerWidget {
  final TitleKey titleKey;

  const CastSection({super.key, required this.titleKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(titleCastProvider(titleKey));
    return cast.when(
      loading: () => _frame(context, child: const _CastSkeleton()),
      error: (error, _) => _frame(
        context,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: Text(detailsErrorMessage(error))),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: () => ref.invalidate(titleCastProvider(titleKey)),
                child: const Text('Tentar novamente'),
              ),
            ],
          ),
        ),
      ),
      data: (members) {
        if (members.isEmpty) return const SizedBox.shrink();
        final shown = members.take(kCastCarouselLimit).toList();
        return _frame(
          context,
          showAll: members.length > kCastCarouselLimit,
          child: _Carousel(members: shown),
        );
      },
    );
  }

  Widget _frame(BuildContext context, {required Widget child, bool showAll = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('Elenco', style: Theme.of(context).textTheme.titleMedium),
                  ),
                ),
                if (showAll)
                  TextButton(
                    style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                    onPressed: () => context.push(castPath(titleKey)),
                    child: const Text('Ver todos'),
                  ),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

double _cardHeight(BuildContext context) =>
    96 + 76 * (MediaQuery.textScalerOf(context).scale(14) / 14);

class _Carousel extends StatelessWidget {
  final List<CastMember> members;

  const _Carousel({required this.members});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _cardHeight(context),
      // Mouse drag is off by default on desktop/web; allow it so the row is
      // not touch-only (keyboard focus also scrolls cards into view).
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          dragDevices: {...PointerDeviceKind.values}..remove(PointerDeviceKind.unknown),
        ),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: members.length,
          separatorBuilder: (_, _) => const SizedBox(width: 4),
          itemBuilder: (_, i) => CastCard(member: members[i]),
        ),
      ),
    );
  }
}

class _CastSkeleton extends StatelessWidget {
  const _CastSkeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Semantics(
      label: 'Carregando elenco',
      child: ExcludeSemantics(
        child: SizedBox(
          height: 96,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 6,
            separatorBuilder: (_, _) => const SizedBox(width: 32),
            itemBuilder: (_, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: DecoratedBox(
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const SizedBox(width: 72, height: 72),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
