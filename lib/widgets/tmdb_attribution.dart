import 'package:flutter/material.dart';

/// Notice required by the TMDB API terms of use.
const kTmdbNotice =
    'This application uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise '
    'approved by TMDB.';

/// Official TMDB logo (assets/tmdb_logo.png, rendered from the public SVG of
/// themoviedb.org/about/logos-attribution) plus the required notice. Small on
/// purpose: less prominent than the CineTrack logo. The logo sits on a light
/// pill so its gradient stays legible in dark mode.
class TmdbAttribution extends StatelessWidget {
  const TmdbAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFFFFF),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Image.asset(
              'assets/tmdb_logo.png',
              width: 110,
              semanticLabel: 'Logo do TMDB',
              errorBuilder: (_, _, _) => const SizedBox(width: 110, height: 14),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text('Dados fornecidos pelo TMDB.', style: style),
        const SizedBox(height: 4),
        Text(kTmdbNotice, style: style),
      ],
    );
  }
}
