/// The companion's one page transition.
///
/// A fade with 4% of a slide, in the app's own [Motion.base] — enough to say
/// the new screen came from the right, short enough that nobody waits for it.
/// Material's platform default on Android is closer to 300ms and zooms the
/// whole page; drilling from a project into its sessions should feel like
/// stepping down a level, not like launching an app.
///
/// Collapses to an instant swap when the platform asks for reduced motion.
library;

import 'package:flutter/material.dart';

import '../../../app/theme/design_tokens.dart';

Route<T> companionRoute<T>(BuildContext context, WidgetBuilder builder) {
  final duration = MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : Motion.base;
  return PageRouteBuilder<T>(
    transitionDuration: duration,
    reverseTransitionDuration: duration,
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) {
      if (duration == Duration.zero) return child;
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOut,
        reverseCurve: Curves.easeIn,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}
