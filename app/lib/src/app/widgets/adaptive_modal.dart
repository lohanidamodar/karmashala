import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// A bottom sheet on a compact window, a dialog elsewhere (PROJECT.md §6).
/// [builder] draws the body only; [title] heads it either way.
///
/// With [heightFactor] the sheet is that share of the window's height, and
/// the body fills what the title leaves, for a body that scrolls itself.
/// Without it the sheet fits the body, which scrolls if it must. [width] is
/// the dialog's.
Future<T?> showAdaptiveModal<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double? heightFactor,
  double width = DialogWidth.narrow,
}) {
  // The window's width, not the caller's: the shell picks its layout by it.
  final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  if (compact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        final heading = Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            0,
            Insets.lg,
            Insets.sm,
          ),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        );
        final factor = heightFactor;
        if (factor != null) {
          return SafeArea(
            top: false,
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * factor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  Expanded(child: builder(context)),
                ],
              ),
            ),
          );
        }
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                heading,
                Flexible(child: SingleChildScrollView(child: builder(context))),
              ],
            ),
          ),
        );
      },
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) {
      final factor = heightFactor;
      final height = MediaQuery.sizeOf(context).height;
      return AlertDialog(
        title: Text(title),
        contentPadding: const EdgeInsets.symmetric(vertical: Insets.md),
        content: BoundedDialogContent(
          width: width,
          child: factor == null
              ? builder(context)
              // A dialog keeps room for its own title and margins.
              : SizedBox(
                  height: math.max(0, math.min(height * factor, height - 200)),
                  child: builder(context),
                ),
        ),
      );
    },
  );
}

/// A bottom sheet on a compact window, elsewhere a popover under the control
/// [context] belongs to — over it, when the control is in the window's
/// bottom half — its end edge on the control's. For a panel of
/// choices that apply as they are made: no barrier tint, and Esc or a click
/// outside closes it. [builder] draws a body that scrolls if it must.
Future<T?> showAdaptivePopover<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double width = DialogWidth.narrow,
}) {
  final size = MediaQuery.sizeOf(context);
  final box = context.findRenderObject() as RenderBox?;
  if (WidthClass.of(size.width).isCompact || box == null || !box.hasSize) {
    return showAdaptiveModal<T>(
      context: context,
      title: title,
      builder: builder,
    );
  }
  final anchor = box.localToGlobal(Offset.zero) & box.size;
  final motion = Motion.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.transparent,
    transitionDuration: motion.fast,
    pageBuilder: (context, _, _) {
      final screen = MediaQuery.sizeOf(context);
      final tones = SurfaceTones.of(context);
      final panelWidth = math.min(width, screen.width - Insets.sm * 2);
      // Under a control in the window's top half; over one in its bottom
      // half — a status line's — where under it there is no room.
      final below = anchor.center.dy < screen.height / 2;
      final top = anchor.bottom + Insets.xs;
      final bottom = screen.height - anchor.top + Insets.xs;
      final room = below
          ? screen.height - top - Insets.sm
          : anchor.top - Insets.xs - Insets.sm;
      final double left = (anchor.right - panelWidth).clamp(
        Insets.sm,
        math.max(Insets.sm, screen.width - panelWidth - Insets.sm),
      );
      return Stack(
        children: [
          Positioned(
            top: below ? top : null,
            bottom: below ? null : bottom,
            left: left,
            width: panelWidth,
            child: Semantics(
              scopesRoute: true,
              namesRoute: true,
              explicitChildNodes: true,
              label: title,
              child: Material(
                color: tones.raised,
                elevation: Elevations.popup,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Radii.md),
                  side: BorderSide(color: tones.floatingLine),
                ),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: math.max(0, room)),
                  child: builder(context),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.enter),
      child: child,
    ),
  );
}

/// A bottom sheet on a compact window, a panel along the window's end edge
/// elsewhere (PROJECT.md §6): for a list read beside the work it describes.
/// [builder] draws a body that scrolls itself.
Future<T?> showAdaptiveSidePanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double width = 440,
}) {
  final size = MediaQuery.sizeOf(context);
  if (WidthClass.of(size.width).isCompact) {
    return showAdaptiveModal<T>(
      context: context,
      title: title,
      builder: builder,
      heightFactor: 0.8,
    );
  }
  final motion = Motion.of(context);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.26),
    transitionDuration: motion.base,
    pageBuilder: (context, _, _) {
      final theme = Theme.of(context);
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: Material(
          elevation: 8,
          color: SurfaceTones.of(context).raised,
          child: SizedBox(
            width: math.min(width, size.width),
            height: double.infinity,
            child: SafeArea(
              left: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Insets.lg,
                      Insets.sm,
                      Insets.sm,
                      Insets.sm,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          icon: const Icon(AppIcons.x),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: builder(context)),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
