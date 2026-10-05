import 'package:flutter/material.dart';

/// Round avatar of someone's public card: the Google photo, or the initial of
/// the nickname. Decorative for screen readers (the nickname and handle are
/// read next to it); a photo that fails to load falls back to the initial.
class PersonAvatar extends StatelessWidget {
  final String? photoUrl;
  final String nickname;
  final double radius;

  const PersonAvatar({super.key, required this.photoUrl, required this.nickname, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    final photo = photoUrl;
    final initial = nickname.isEmpty
        ? '@'
        : String.fromCharCode(nickname.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        foregroundImage: photo == null ? null : NetworkImage(photo),
        onForegroundImageError: photo == null ? null : (_, _) {},
        child: Text(initial),
      ),
    );
  }
}
