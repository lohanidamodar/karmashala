import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_git/git.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../editor/application/code_editor_providers.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../application/changes_providers.dart';
import '../application/diff_tab_actions.dart';
import 'diff_counts.dart';
import 'diff_view.dart';

/// One file's diff, as the content of a workbench tab. The sidebar lists what
/// changed; reading a change happens here, with the room to do it.
class DiffTabView extends ConsumerWidget {
  const DiffTabView({required this.target, super.key});

  final DiffTarget target;

  /// The file itself on this host, or null when the checkout has no spelling
  /// here — an SSH checkout's files are on the other machine.
  String? _hostFile(WidgetRef ref) {
    final root = ref
        .read(editorActionsProvider)
        .windowsPathFor(target.checkout);
    return root == null ? null : p.normalize(p.join(root, target.path));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(diffForTargetProvider(target));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, ref, diff.asData?.value),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => FileDiffView(
              path: target.path,
              checkout: target.checkout,
              // This tab's own repository, so its review threads cannot follow
              // the sidebar onto another one.
              repositoryId: ref.watch(
                repositoryIdForCheckoutProvider(target.checkout),
              ),
              // At least the viewport, so a short diff does not scroll
              // sideways, and never narrower than the lines it has to hold.
              scrollWidth: math.max(constraints.maxWidth, 1400),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, String? diff) {
    final hostFile = _hostFile(ref);
    return PaneHeader(
      icon: AppIcons.gitDiff,
      title: target.name,
      actions: [
        if (diff != null) _DiffCounts(diff: diff),
        IconButton(
          tooltip: hostFile == null
              ? "This checkout's files are not on this machine"
              : 'Open the file',
          visualDensity: VisualDensity.compact,
          iconSize: Chrome.iconAction,
          icon: const Icon(AppIcons.fileCode),
          onPressed: hostFile == null
              ? null
              : () => ref.read(editorTabActionsProvider).open(hostFile),
        ),
        IconButton(
          tooltip: 'Copy diff',
          visualDensity: VisualDensity.compact,
          iconSize: Chrome.iconAction,
          icon: const Icon(AppIcons.copySimple),
          onPressed: diff == null || diff.isEmpty
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: diff));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Diff copied to clipboard')),
                    );
                  }
                },
        ),
        IconButton(
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
          iconSize: Chrome.iconAction,
          icon: const Icon(AppIcons.arrowsClockwise),
          onPressed: () => ref.invalidate(diffForTargetProvider(target)),
        ),
      ],
    );
  }
}

/// `+N −M` for a diff already in hand. Counted from the text rather than asked
/// of git again: this is the very diff on screen, so the two cannot disagree.
class _DiffCounts extends StatelessWidget {
  const _DiffCounts({required this.diff});

  final String diff;

  @override
  Widget build(BuildContext context) {
    var added = 0;
    var removed = 0;
    for (final line in parseUnifiedDiff(diff)) {
      if (line.kind == DiffLineKind.added) added++;
      if (line.kind == DiffLineKind.removed) removed++;
    }
    if (added == 0 && removed == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: Insets.xs),
      child: DiffCountLabel(added: added, removed: removed),
    );
  }
}
