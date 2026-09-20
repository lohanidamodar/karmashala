import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../editor/application/code_editor_providers.dart';
import '../../editor/application/editor_tab_actions.dart';
import '../application/changes_providers.dart';
import '../application/diff_tab_actions.dart';
import '../application/parsed_diff.dart';
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
    final parsed = ref.watch(parsedDiffProvider(target)).asData?.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DiffTabHeader(
          target: target,
          counts: parsed == null
              ? null
              : (added: parsed.added, removed: parsed.removed),
          hostFile: _hostFile(ref),
        ),
        Expanded(
          child: FileDiffView(
            path: target.path,
            checkout: target.checkout,
            // This tab's own repository, so its review threads cannot follow
            // the sidebar onto another one.
            repositoryId: ref.watch(
              repositoryIdForCheckoutProvider(target.checkout),
            ),
          ),
        ),
      ],
    );
  }
}

/// A diff tab's header: the file, its `+N −M`, and what can be done with it.
class DiffTabHeader extends ConsumerWidget {
  const DiffTabHeader({
    required this.target,
    required this.counts,
    required this.hostFile,
    super.key,
  });

  final DiffTarget target;

  /// Null until the diff has loaded.
  final ({int added, int removed})? counts;

  /// See [DiffTabView]; null disables Open.
  final String? hostFile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diff = ref.watch(diffForTargetProvider(target)).asData?.value;
    final counts = this.counts;
    final hostFile = this.hostFile;
    return PaneHeader(
      icon: AppIcons.gitDiff,
      title: target.name,
      actions: [
        if (counts != null && (counts.added > 0 || counts.removed > 0))
          Padding(
            padding: const EdgeInsets.only(right: Insets.xs),
            child: DiffCountLabel(added: counts.added, removed: counts.removed),
          ),
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
