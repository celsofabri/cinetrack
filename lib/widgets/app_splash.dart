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

  const AppSplash({
    super.key,
    required this.child,
    this.hold = const Duration(milliseconds: 700),
    this.fade = const Duration(milliseconds: 600),
  });

  @override
  State<AppSplash> createState() => _AppSplashState();
}

class _AppSplashState extends State<AppSplash> {
  bool _fading = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.hold, () {
      if (mounted) setState(() => _fading = true);
    });
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
