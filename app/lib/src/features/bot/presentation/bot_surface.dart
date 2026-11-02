import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../application/bot_providers.dart';
import 'bot_panel.dart';

/// **The desktop's bot**: a floating panel at the right of the window, over
/// whatever the person is doing. Nothing under it is held back, and it stays
/// up across navigation until closed. The shell places it.
class BotFloatingPanel extends ConsumerWidget {
  const BotFloatingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tones = SurfaceTones.of(context);
    return DecoratedBox(
      key: const ValueKey('bot-panel'),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        boxShadow: Shadows.floating,
      ),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: tones.floatingLine),
        ),
        child: BotPanelView(onClose: ref.read(botPanelProvider.notifier).close),
      ),
    );
  }
}

/// **The phone's bot**: a bottom sheet of about [Chrome.botSheetShare] of the
/// height, raised while the panel flag is up. The flag is the one truth: a
/// window that widens takes the sheet down and leaves the flag, and the
/// desktop's panel stands in its place.
class BotPhoneSheetHost extends ConsumerStatefulWidget {
  const BotPhoneSheetHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<BotPhoneSheetHost> createState() => _BotPhoneSheetHostState();
}

class _BotPhoneSheetHostState extends ConsumerState<BotPhoneSheetHost> {
  NavigatorState? _navigator;
  ModalRoute<void>? _sheet;

  void _raise() {
    if (_sheet != null || !mounted) return;
    final navigator = _navigator = Navigator.of(context, rootNavigator: true);
    final route = ModalBottomSheetRoute<void>(
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
      builder: (_) => const _BotSheet(),
    );
    _sheet = route;
    unawaited(
      navigator.push(route).then((_) {
        if (!identical(_sheet, route)) return;
        _sheet = null;
        if (mounted) ref.read(botPanelProvider.notifier).close();
      }),
    );
  }

  void _lower() {
    final route = _sheet;
    _sheet = null;
    if (route != null && route.isActive) _navigator?.removeRoute(route);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ref.read(botPanelProvider)) _raise();
    });
  }

  @override
  void dispose() {
    _lower();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(botPanelProvider, (_, open) => open ? _raise() : _lower());
    return widget.child;
  }
}

class _BotSheet extends ConsumerWidget {
  const _BotSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final room = media.size.height - keyboard;
    final wanted = media.size.height * Chrome.botSheetShare;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        key: const ValueKey('bot-sheet'),
        height: wanted < room ? wanted : room,
        // Its own messenger: a snack bar raised here shows over the sheet,
        // not behind it.
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: BotPanelView(
              phone: true,
              onClose: ref.read(botPanelProvider.notifier).close,
            ),
          ),
        ),
      ),
    );
  }
}
