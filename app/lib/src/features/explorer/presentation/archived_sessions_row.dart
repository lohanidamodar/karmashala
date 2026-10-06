import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/session_list_prefs.dart';
import 'sidebar_chrome.dart';

/// The row a session list ends with while archived sessions exist: "Archived
/// (N)" turns "Show archived" on, and "Hide archived" turns it off again.
class ArchivedSessionsRow extends ConsumerWidget {
  const ArchivedSessionsRow({
    required this.count,
    this.depth = 0,
    super.key,
  });

  /// How many archived sessions this list holds back, or shows.
  final int count;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final showing = ref.watch(showArchivedSessionsProvider);
    return ExplorerRow(
      kind: ExplorerRowKind.session,
      minHeight: Sidebar.rowHeight,
      depth: depth,
      selected: false,
      onTap: () => ref
          .read(sessionListPrefsProvider.notifier)
          .setShowArchived(!showing),
      builder: (context) => ExplorerRowLine(
        lead: ExplorerRowLead(
          glyph: Icon(AppIcons.tray, size: ExplorerRow.glyphSize),
        ),
        title: Text(
          showing ? 'Hide archived' : 'Archived ($count)',
          style: UiDensity.of(context).muted(Theme.of(context)),
        ),
      ),
    );
  }
}
