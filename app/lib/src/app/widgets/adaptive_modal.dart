import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:karmashala_ui/dialogs.dart';
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
