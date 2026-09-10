import 'package:flutter/material.dart';

/// The heading over one group of devices, with the one control that governs
/// it. Shared, so three indents down one column do not read as three panels.
class DeviceSectionHeader extends StatelessWidget {
  const DeviceSectionHeader({required this.title, this.action, super.key});

  final String title;

  /// The group's own control — "Slimming". On the heading because it decides
  /// how everything in the group below will start, not how one row will.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    // The right inset is smaller because a `TextButton` carries its own
    // padding; without that the action hangs further out than the rows.
    padding: EdgeInsets.fromLTRB(16, 0, action == null ? 16 : 8, 0),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.labelLarge),
        ),
        ?action,
      ],
    ),
  );
}
