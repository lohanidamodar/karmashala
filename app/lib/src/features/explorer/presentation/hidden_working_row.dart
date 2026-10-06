import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/session_list_prefs.dart';
import 'sidebar_chrome.dart';

/// "N working · Show": where "Hide while working" took sessions off a list.
/// Show turns the switch off.
class HiddenWorkingRow extends ConsumerWidget {
  const HiddenWorkingRow({required this.count, this.depth = 0, super.key});

  final int count;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Semantics(
    button: true,
    label: '$count working, hidden. Show',
    excludeSemantics: true,
    child: ExplorerRow(
      kind: ExplorerRowKind.session,
      minHeight: Sidebar.rowHeight,
      depth: depth,
      selected: false,
      onTap: () =>
          ref.read(sessionListPrefsProvider.notifier).setHideWorking(false),
      builder: (context) => ExplorerRowLine(
        lead: ExplorerRowLead(
          glyph: Icon(AppIcons.eyeSlash, size: ExplorerRow.glyphSize),
        ),
        title: Text(
          '$count working · Show',
          style: UiDensity.of(context).muted(Theme.of(context)),
        ),
      ),
    ),
  );
}
