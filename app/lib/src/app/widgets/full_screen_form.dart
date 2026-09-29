import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';

/// Whether a form dialog opens full screen: by the window's width, as the
/// shell picks its layout (PROJECT.md §6), never the platform.
bool opensFullScreen(BuildContext context) =>
    WidthClass.of(MediaQuery.sizeOf(context).width).isCompact;

/// `showDialog` for a form that draws [FullScreenForm] at compact: that frame
/// keeps its own safe area, so the route adds none.
Future<T?> showFormDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDialog<T>(
  context: context,
  useSafeArea: !opensFullScreen(context),
  builder: builder,
);

/// A form dialog's compact frame: the title in an app bar with a close button
/// and [primary] beside it, where a keyboard never covers them, and [body]
/// scrolling under it.
class FullScreenForm extends StatelessWidget {
  const FullScreenForm({
    required this.title,
    required this.body,
    required this.primary,
    required this.onClose,
    super.key,
  });

  final String title;
  final Widget body;

  /// The form's commit button.
  final Widget primary;

  /// What the close button does; null disables it.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: 'Cancel',
          icon: const Icon(AppIcons.x),
          onPressed: onClose,
        ),
        titleSpacing: 0,
        title: Text(title),
        actions: [
          Padding(
            padding: const EdgeInsetsDirectional.only(end: Insets.md),
            child: primary,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.lg),
          child: body,
        ),
      ),
    ),
  );
}
