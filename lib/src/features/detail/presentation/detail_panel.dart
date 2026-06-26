import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/shell/shell_state.dart';

/// Right pane — Detail (chat transcript, diffs, and review for the selected
/// session).
///
/// Placeholder for Loop 0. Diff review arrives in Loop 9; the chat transcript
/// from Loop 6.
class DetailPanel extends ConsumerWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focused =
        ref.watch(shellControllerProvider).focusedPane == ShellPane.detail;
    return PaneScaffold(
      title: 'Detail',
      icon: Icons.article_outlined,
      focused: focused,
      body: const PanePlaceholder(
        message:
            'Session transcript and Git diff review will appear here.\nReview arrives in Loop 9.',
      ),
    );
  }
}
