import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'pane_scaffold.dart';

/// **Every workbench page tab's frame** — Stores, Usage, Logs: a
/// [Chrome.tabAppBarOf] bar with the tab's glyph in the tertiary ink, its
/// name, its [controls] and its [actions], over [body].
///
/// Under a [PaneTitleOverride] (the phone's More page, which names it
/// already) there is no bar: the controls and actions wrap in a strip above
/// the body. A compact tab keeps its bar but moves the controls to that strip,
/// where they cannot push the name off.
class WorkbenchTabScaffold extends StatelessWidget {
  const WorkbenchTabScaffold({
    required this.icon,
    required this.title,
    required this.body,
    this.controls = const [],
    this.actions = const [],
    this.backgroundColor,
    this.oneRowStrip = false,
    super.key,
  });

  /// Under a [PaneTitleOverride], whether the strip keeps the controls and
  /// actions on one row — the controls shrinking to fit — rather than
  /// wrapping the actions under them. For a root tab, whose row is its only
  /// header.
  final bool oneRowStrip;

  final IconData icon;
  final String title;

  /// After the name — a compact view or range switcher.
  final List<Widget> controls;

  /// At the bar's end, typically icon buttons.
  final List<Widget> actions;
  final Widget body;
  final Color? backgroundColor;

  /// The room the glyph and the name keep in the bar, at 1x text.
  static const minTitleWidth = 96.0;

  @override
  Widget build(BuildContext context) {
    if (PaneTitleOverride.maybeOf(context) != null) {
      if (oneRowStrip) {
        return Scaffold(
          backgroundColor: backgroundColor,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                key: const ValueKey('workbench-tab-strip'),
                padding: const EdgeInsets.fromLTRB(
                  Insets.lg,
                  Insets.xs,
                  Insets.xs,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: controls,
                          ),
                        ),
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
              Expanded(child: body),
            ],
          ),
        );
      }
      return Scaffold(
        backgroundColor: backgroundColor,
        body: _withStrip([
          if (controls.isNotEmpty) _wrap(controls),
          if (actions.isNotEmpty)
            Row(mainAxisSize: MainAxisSize.min, children: actions),
        ]),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        final inBar =
            controls.isNotEmpty &&
            !WidthClass.of(constraints.maxWidth, textScaler: scaler).isCompact;
        // The name keeps room for a few words; past that the actions give way
        // to the strip rather than squeeze it to nothing.
        final actionsInBar =
            constraints.maxWidth >=
            actions.length * Touch.target + scaler.scale(minTitleWidth);
        final strip = [
          if (controls.isNotEmpty && !inBar) _wrap(controls),
          if (actions.isNotEmpty && !actionsInBar)
            Row(mainAxisSize: MainAxisSize.min, children: actions),
        ];
        return Scaffold(
          backgroundColor: backgroundColor,
          appBar: AppBar(
            toolbarHeight: Chrome.tabAppBarOf(context),
            // A workbench tab: an implied back button would pop the app's
            // route.
            automaticallyImplyLeading: false,
            title: Row(
              children: [
                Icon(icon, color: Theme.of(context).colorScheme.tertiary),
                const SizedBox(width: Insets.sm),
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (inBar) ...[const SizedBox(width: Insets.lg), ...controls],
              ],
            ),
            actions: [
              if (actionsInBar) ...actions,
              const SizedBox(width: Insets.sm),
            ],
          ),
          body: _withStrip(strip),
        );
      },
    );
  }

  Widget _wrap(List<Widget> children) => Wrap(
    spacing: Touch.gap,
    runSpacing: Insets.xs,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: children,
  );

  Widget _withStrip(List<Widget> strip) {
    if (strip.isEmpty) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Insets.lg,
            Insets.sm,
            Insets.sm,
            0,
          ),
          // Large text can push the actions under the controls.
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Touch.gap,
            runSpacing: Insets.xs,
            children: strip,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}
