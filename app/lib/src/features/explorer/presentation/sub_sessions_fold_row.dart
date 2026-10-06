import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/rows.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../sessions/application/session_list_prefs.dart';
import 'sidebar_chrome.dart';

/// "12 sub-sessions · 2 running" beneath a parent session: folds or opens its
/// ended sub-sessions, and this device remembers which.
class SubSessionsFoldRow extends ConsumerWidget {
  const SubSessionsFoldRow({
    required this.parentId,
    required this.label,
    required this.folded,
    required this.depth,
    super.key,
  });

  final String parentId;
  final String label;
  final bool folded;
  final int depth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void toggle() =>
        ref.read(sessionListPrefsProvider.notifier).setFolded(parentId, !folded);
    return ExplorerRow(
      kind: ExplorerRowKind.session,
      minHeight: Sidebar.rowHeight,
      depth: depth,
      selected: false,
      onTap: toggle,
      builder: (context) => ExplorerRowLine(
        lead: ExplorerRowLead(expanded: !folded, onDisclosure: toggle),
        title: Text(
          label,
          style: UiDensity.of(context).muted(Theme.of(context)),
        ),
      ),
    );
  }
}
