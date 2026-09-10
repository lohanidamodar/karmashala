/// The companion's one page transition: a fade with 4% of a slide at
/// [Motion.base], against Material's ~300ms whole-page zoom. Collapses to an
/// instant swap when the platform asks for reduced motion.
library;

import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

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
