import 'package:flutter/material.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

/// The value a row menu's "More…" entry answers with.
const String kMoreMenuValue = 'more';

/// "More…": the way into a row's rarer verbs, opened as a second menu where
/// the row's own opened — popup menus here do not nest.
PopupMenuEntry<String> moreMenuItem() => DesktopMenuItem(
  value: kMoreMenuValue,
  label: 'More…',
  icon: AppIcons.dotsThree,
);

/// Opens [items] against the row [context] belongs to: a sheet under a thumb,
/// else a menu under the row's leading edge. Resolves to the value picked.
Future<String?> showMoreMenu(
  BuildContext context,
  List<PopupMenuEntry<String>> items,
) async {
  if (items.isEmpty) return null;
  if (RowMenuSheetScope.touchOf(context) case final present?) {
    return present(context, 'More', items);
  }
  final box = context.findRenderObject() as RenderBox?;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.hasSize) return null;
  final origin = box.localToGlobal(
    Offset(Insets.lg, box.size.height),
    ancestor: overlay,
  );
  return showDesktopMenuAt(context, origin, items);
}
