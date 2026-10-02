import 'dart:async';

import 'package:flutter/material.dart';

/// Brand purple shared by every splash surface (web HTML, Android, iOS and
/// this widget) so hand-offs between them are seamless.
const kSplashColor = Color(0xFF5E2CA5);

/// Full-screen splash (logo + name) laid over the app that fades out
/// smoothly once the home is up. Web/Android/iOS show their own native
/// splash until Flutter draws its first frame; this widget continues from
/// the exact same image and takes over the fade.
class AppSplash extends StatefulWidget {
  final Widget child;
  final Duration hold;
  final Duration fade;

  /// The splash only starts fading once this is true (and [hold] elapsed).
  /// The app passes "first auth event received" so the signed-out UI never
  /// flashes before the session is known.
  final bool ready;

  /// Safety cap: if [ready] never becomes true (e.g. the auth stream never
  /// emits because browser storage is blocked) the splash fades anyway after
  /// this long, so the public catalog never stays hidden. The UI then
  /// continues as signed out until a session event arrives.
  final Duration maxWait;

  const AppSplash({
    super.key,
    required this.child,
    this.hold = const Duration(milliseconds: 700),
    this.fade = const Duration(milliseconds: 600),
    this.ready = true,
    this.maxWait = const Duration(seconds: 3),
  });

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash> {
  bool _holdElapsed = false;
  bool _gone = false;
  bool _timedOut = false;
  Timer? _maxWaitTimer;

  bool get _fading => _holdElapsed && (widget.ready || _timedOut);

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.hold, () {
      if (mounted) setState(() => _holdElapsed = true);
    });
    // Only armed while the session is unknown; cancelled once it is ready.
    if (!widget.ready) {
      _maxWaitTimer = Timer(widget.maxWait, () {
        if (mounted) setState(() => _timedOut = true);
      });
    }
  }

  @override
  void didUpdateWidget(AppSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.ready) _maxWaitTimer?.cancel();
  }

  @override
  void dispose() {
    _maxWaitTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: widget.child),
        if (!_gone)
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: widget.fade,
                curve: Curves.easeOut,
                onEnd: () {
                  if (_fading && mounted) setState(() => _gone = true);
                },
                child: const ColoredBox(
                  color: kSplashColor,
                  child: Center(
                    child: Image(
                      image: AssetImage('assets/splash_logo.png'),
                      width: 225,
                      excludeFromSemantics: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
