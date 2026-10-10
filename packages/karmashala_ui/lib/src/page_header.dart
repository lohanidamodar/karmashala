import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'design_tokens.dart';

/// Set by a page pushed with a way back — the phone's More pages — whose
/// header is drawn by the page itself, in one row: [PageHeaderBar] reads it,
/// and so do `WorkbenchTabScaffold` and `PaneHeader`, so a page's own
/// controls share the row with the back arrow and the name.
class PageHeaderScope extends InheritedWidget {
  const PageHeaderScope({
    required String this.title,
    required VoidCallback this.onBack,
    required super.child,
    super.key,
  });

  /// Under a header that drew the page's row already: a frame inside its
  /// body draws its own header again.
  const PageHeaderScope.claimed({required super.child, super.key})
    : title = null,
      onBack = null;

  final String? title;
  final VoidCallback? onBack;

  static PageHeaderScope? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PageHeaderScope>();
    return scope?.title == null ? null : scope;
  }

  @override
  bool updateShouldNotify(PageHeaderScope oldWidget) =>
      title != oldWidget.title || onBack != oldWidget.onBack;
}

/// **A pushed page's one-row header** (round 86): back, the name at a normal
/// size, the page's [controls] and its [actions] — the Dashboard's one row
/// with a way back. [controls] that do not fit beside the name sit compact
/// under it rather than squeezing it.
class PageHeaderBar extends StatelessWidget {
  const PageHeaderBar({
    required this.title,
    required this.onBack,
    this.controls = const [],
    this.actions = const [],
    super.key,
  });

  /// Drawn from the nearest [PageHeaderScope]; nothing outside one.
  static Widget? maybeFor(
    BuildContext context, {
    List<Widget> controls = const [],
    List<Widget> actions = const [],
  }) {
    final scope = PageHeaderScope.maybeOf(context);
    if (scope == null) return null;
    return PageHeaderBar(
      title: scope.title!,
      onBack: scope.onBack!,
      controls: controls,
      actions: actions,
    );
  }

  final String title;
  final VoidCallback onBack;
  final List<Widget> controls;
  final List<Widget> actions;

  /// The room the name keeps beside the controls, at 1x text.
  static const minTitleWidth = 96.0;

  /// The room the controls take in the row, at 1x text: a three-way switcher.
  static const minControlsWidth = 200.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final inRow =
            controls.isEmpty ||
            constraints.maxWidth >=
                (actions.length + 1) * Touch.target +
                    Insets.lg +
                    scaler.scale(minTitleWidth + minControlsWidth);
        final name = Text(
          title,
          key: const ValueKey('page-header-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        );
        final row = ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Touch.target),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('page-header-back'),
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(AppIcons.arrowLeft),
                onPressed: onBack,
              ),
              const SizedBox(width: Insets.xxs),
              if (inRow && controls.isNotEmpty) ...[
                Flexible(child: name),
                const SizedBox(width: Insets.md),
                // Never wider than the row leaves it: a control shrinks
                // rather than overflows.
                Expanded(
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerEnd,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: controls,
                      ),
                    ),
                  ),
                ),
              ] else
                Expanded(child: name),
              ...actions,
            ],
          ),
        );
        return Padding(
          key: const ValueKey('page-header'),
          padding: const EdgeInsets.fromLTRB(
            Insets.xxs,
            Insets.xxs,
            Insets.xs,
            Insets.xxs,
          ),
          child: inRow
              ? row
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    row,
                    Padding(
                      key: const ValueKey('page-header-controls'),
                      padding: const EdgeInsets.fromLTRB(
                        Insets.md,
                        0,
                        0,
                        Insets.xxs,
                      ),
                      child: Wrap(
                        spacing: Touch.gap,
                        runSpacing: Insets.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: controls,
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
