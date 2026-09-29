import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_remote/client.dart';

import '../application/route_pin_controller.dart';

/// *Use Auto* on a link strip while the active machine's route is pinned:
/// clears the pin and dials again. Nothing when the route is automatic.
class UseAutoButton extends ConsumerWidget {
  const UseAutoButton({this.foreground, super.key});

  /// The strip's text colour, where the strip is not on the surface.
  final Color? foreground;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pin = ref.watch(routePinProvider).value;
    if (pin == null || pin.isAuto) return const SizedBox.shrink();
    return TextButton(
      key: const ValueKey('link_use_auto'),
      style: foreground == null
          ? null
          : TextButton.styleFrom(foregroundColor: foreground),
      onPressed: () => unawaited(
        ref.read(routePinProvider.notifier).choose(CompanionRoutePin.auto),
      ),
      child: const Text('Use Auto'),
    );
  }
}
