import 'package:flutter/material.dart';

/// The heading over one group of devices, with the one control that governs
/// that group.
///
/// Shared by the Android sections and the iOS one because they sit in the same
/// scroll view, one under the other, and were laid out by different hands: the
/// Android headings inherited the pane's centred `Column` while every row under
/// them was inset 16, and the iOS heading was inset 16 while its picker was
/// inset differently again. Three indents down one narrow column reads as three
/// unrelated panels rather than one list of devices.
class DeviceSectionHeader extends StatelessWidget {
  const DeviceSectionHeader({required this.title, this.action, super.key});

  final String title;

  /// The group's own control — "Slimming" on both platforms. Sits on the
  /// heading rather than beside a Start button, because it decides how
  /// everything in the group below will start, not how one row will.
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    // The right inset is smaller because a `TextButton` carries its own
    // padding; without that the action would hang further from the edge than
    // the rows do.
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
