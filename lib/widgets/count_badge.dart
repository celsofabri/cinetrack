import 'package:flutter/material.dart';

import '../social/social_models.dart';

/// Text of the number on a badge: the real number up to one below the cap,
/// "50+" at the cap (the count is capped at [kMaxReceivedListed]).
String badgeText(int count) => count >= kMaxReceivedListed ? '$kMaxReceivedListed+' : '$count';

/// Screen-reader text of the Amigos entry: starts with the visible word
/// ("Amigos") and adds the number the badge shows.
String friendsSemanticLabel(int pending) => switch (pending) {
  <= 0 => 'Amigos',
  1 => 'Amigos, 1 pedido recebido',
  >= kMaxReceivedListed => 'Amigos, $kMaxReceivedListed ou mais pedidos recebidos',
  _ => 'Amigos, $pending pedidos recebidos',
};

/// Same for the Perfil destination when the Amigos icon does not fit and the
/// badge becomes a dot there (docs/50 §13).
String profileSemanticLabel(int pending) => switch (pending) {
  <= 0 => 'Perfil',
  1 => 'Perfil, 1 pedido de amizade recebido',
  _ => 'Perfil, ${pending >= kMaxReceivedListed ? 'vários' : pending} pedidos de amizade recebidos',
};

/// Numeric badge (or a dot) over [child]. The number is hidden from screen
/// readers on purpose: the owner puts the full sentence in its own label
/// ([friendsSemanticLabel]), so it is never read twice.
class CountBadge extends StatelessWidget {
  final int count;
  final bool dot;
  final Widget child;

  const CountBadge({super.key, required this.count, required this.child, this.dot = false});

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: count > 0,
      label: dot ? null : ExcludeSemantics(child: Text(badgeText(count))),
      child: child,
    );
  }
}
