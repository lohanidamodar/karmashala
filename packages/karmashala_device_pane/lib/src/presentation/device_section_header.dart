import 'package:flutter/material.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import 'device_list_row.dart';

/// The heading over one group of devices — the app's group label, as in the
/// Explorer and Settings — with the one control that governs the group at the
/// right, in the column the rows' own actions end in.
class DeviceSectionHeader extends StatelessWidget {
  const DeviceSectionHeader({required this.title, this.action, super.key});

  /// Written in any case; drawn uppercase.
  final String title;

  /// The group's own control — a [DeviceSectionAction]. On the heading because
  /// it decides how everything in the group will start, not how one row will.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final density = UiDensity.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: DeviceListMetrics.inset,
        right: action == null
            ? DeviceListMetrics.inset
            : DeviceListMetrics.inset - DeviceListMetrics.glyphMargin(density),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: ExplorerRow.slotOf(density)),
        child: Row(
          children: [
            Expanded(child: EyebrowLabel(title, maxLines: 1)),
            ?action,
          ],
        ),
      ),
    );
  }
}

/// The settings of a group of devices, behind a gear in a row action's slot.
class DeviceSectionAction extends StatelessWidget {
  const DeviceSectionAction({
    required this.tooltip,
    required this.onPressed,
    this.icon = AppIcons.gearSix,
    super.key,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      ExplorerRowAction(tooltip: tooltip, icon: icon, onPressed: onPressed);
}
