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
/// Without it the sheet fits the body, which scrolls if it must.
Future<T?> showAdaptiveModal<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  double? heightFactor,
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
          width: DialogWidth.narrow,
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
    barrierColor: Colors.black26,
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
