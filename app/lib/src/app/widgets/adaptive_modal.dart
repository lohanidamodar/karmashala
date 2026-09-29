import 'package:flutter/material.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

/// A bottom sheet on a compact window, a dialog elsewhere (PROJECT.md §6).
/// [builder] draws the body only; [title] heads it either way.
Future<T?> showAdaptiveModal<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
}) {
  // The window's width, not the caller's: the shell picks its layout by it.
  final compact = WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;
  if (compact) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: Insets.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  0,
                  Insets.lg,
                  Insets.sm,
                ),
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Flexible(child: SingleChildScrollView(child: builder(context))),
            ],
          ),
        ),
      ),
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: Insets.md),
      content: BoundedDialogContent(
        width: DialogWidth.narrow,
        child: builder(context),
      ),
    ),
  );
}
