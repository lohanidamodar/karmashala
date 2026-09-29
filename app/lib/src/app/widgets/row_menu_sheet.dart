import 'package:flutter/material.dart';
import 'package:karmashala_ui/menus.dart';

import 'adaptive_modal.dart';

/// A row's ⋮ under a thumb: its entries as 48dp rows in [showAdaptiveModal].
Future<String?> showRowMenuSheet(
  BuildContext context,
  String title,
  List<PopupMenuEntry<String>> items,
) => showAdaptiveModal<String>(
  context: context,
  title: title,
  builder: (_) => MenuSheetList<String>(items: items),
);
