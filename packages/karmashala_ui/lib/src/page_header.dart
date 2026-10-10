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
/// with a way back. [controls] sit beside the name when they fit at their
/// own size, so a thumb keeps its targets; when they do not, they sit under
/// it instead.
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

  @override
  Widget build(BuildContext context) {
    final name = ConstrainedBox(
      // As tall as the back button beside it, so the two share a line.
      constraints: const BoxConstraints(minHeight: Touch.target),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: Text(
          title,
          key: const ValueKey('page-header-title'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            key: const ValueKey('page-header-back'),
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            icon: const Icon(AppIcons.arrowLeft),
            onPressed: onBack,
          ),
          const SizedBox(width: Insets.xxs),
          Expanded(
            child: controls.isEmpty
                ? name
                : OverflowBar(
                    alignment: MainAxisAlignment.spaceBetween,
                    overflowAlignment: OverflowBarAlignment.start,
                    spacing: Insets.md,
                    overflowSpacing: Insets.xxs,
                    children: [
                      name,
                      // Measured within the row: a switcher wider than it
                      // narrows its segments, never scales its targets.
                      Wrap(
                        key: const ValueKey('page-header-controls'),
                        spacing: Touch.gap,
                        runSpacing: Insets.xs,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: controls,
                      ),
                    ],
                  ),
          ),
          for (final action in actions) _onFirstLine(action),
        ],
      ),
    );
  }

  /// [action] centred on the back button's line, however tall the header
  /// grows under it; a [Flexible] one keeps its flex.
  static Widget _onFirstLine(Widget action) {
    Widget line(Widget child) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Touch.target),
      child: Align(widthFactor: 1, heightFactor: 1, child: child),
    );
    return action is Flexible
        ? Flexible(
            flex: action.flex,
            fit: action.fit,
            child: line(action.child),
          )
        : line(action);
  }
}
