import 'package:flutter/material.dart';

import 'package:karmashala_ui/tokens.dart';

/// A device's name, a line about it, and what can be done to it. Side by side
/// where there is room for the name *and* the actions; otherwise the actions
/// wrap onto their own line under the name, so the name is never the part that
/// gives way.
///
/// Not a `ListTile`: its trailing slot takes whatever the actions ask for, and
/// three text buttons in a 240px side panel left the name 6px — then threw.
class DeviceActionRow extends StatelessWidget {
  const DeviceActionRow({
    required this.title,
    this.subtitle,
    this.actions = const [],
    super.key,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  /// The least a name needs beside its actions, at 1x text.
  static const nameWidth = 180.0;

  /// What one text action is budgeted, at 1x text.
  static const actionWidth = 110.0;

  /// The narrowest width, at 1x text, that holds [count] actions beside a name.
  static double sideBySideFrom(int count) => nameWidth + actionWidth * count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium,
        ),
        if (subtitle case final line?)
          Text(
            line,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
    return Padding(
      // The right inset is smaller because a `TextButton` carries its own
      // padding; without that the actions hang further in than the name.
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.xs,
        Insets.xs,
        Insets.xs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (actions.isEmpty) {
            return Align(alignment: Alignment.centerLeft, child: text);
          }
          final sideBySide =
              constraints.maxWidth >=
              WidthClass.scaleBreakpoint(
                sideBySideFrom(actions.length),
                scaler,
              );
          if (sideBySide) {
            return Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: Insets.sm),
                // Flexible, so even a budget that was wrong wraps the actions
                // rather than overflowing the row.
                Flexible(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              text,
              // Pulled back by a text button's own padding, so the first
              // label lines up under the name rather than indented from it.
              Transform.translate(
                offset: const Offset(-Insets.md, 0),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
