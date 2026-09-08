import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../../git/data/git_diff_parsing.dart';
import '../../git/domain/diff_line.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../application/checkpoint_providers.dart';
import '../application/checkpoint_service.dart';
import '../domain/checkpoint.dart';

/// Which session's checkpoints the panel is describing.
///
/// The session **on screen**, not the one last clicked in the Explorer — the
/// same rule [planPanelSessionIdProvider] and [mediaPanelSessionIdProvider]
/// follow, and for the same reason: switching terminal tabs changes which
/// agent has been editing your checkout.
final checkpointsPanelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(activePaneSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// **The checkpoints of a session, and the way back to one.**
///
/// Deliberately plain. The place this belongs is beside the turn it belongs to,
/// in the transcript — that is the sessions owner's surface, and a follow-up.
/// Until then this is the honest minimum: a list you can read, a diff you can
/// check, and a restore that tells you what it will cost before it does it.
///
/// Nothing here polls. The list is read when the panel opens and again when a
/// checkpoint is written, and **every row carries the age of its capture**
/// (§19) — a chain of turns with no ages on it cannot be used to pick the one
/// you meant.
class CheckpointsView extends ConsumerStatefulWidget {
  const CheckpointsView({super.key});

  @override
  ConsumerState<CheckpointsView> createState() => _CheckpointsViewState();
}

class _CheckpointsViewState extends ConsumerState<CheckpointsView> {
  String? _expandedId;
  String? _busyId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionId = ref.watch(checkpointsPanelSessionIdProvider);
    if (sessionId == null) {
      return const PanePlaceholder(
        message: 'Open a session to see the checkpoints of its turns.',
        icon: AppIcons.clockCounterClockwise,
      );
    }

    final checkpoints = ref.watch(sessionCheckpointsProvider(sessionId));
    if (checkpoints.isEmpty) {
      return const PanePlaceholder(
        message: 'No checkpoints yet. One is recorded each time this session '
            'finishes a turn.',
        icon: AppIcons.clockCounterClockwise,
      );
    }

    final now = ref.watch(clockProvider).nowUtc();
    return ListView.separated(
      itemCount: checkpoints.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final checkpoint = checkpoints[index];
        final expanded = _expandedId == checkpoint.id;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              dense: true,
              title: Text(
                checkpoint.label ??
                    '${_reasonLabel(checkpoint.reason)} '
                        '#${checkpoint.sequence}',
                style: theme.textTheme.bodyMedium,
              ),
              // §19 at the line the reading is on: a turn is only pickable if
              // you can tell how long ago it was.
              subtitle: Text(
                '${checkpoint.files.length} file'
                '${checkpoint.files.length == 1 ? '' : 's'} · '
                '${describeAge(now.difference(checkpoint.createdAt))}',
                style: theme.textTheme.bodySmall,
              ),
              onTap: () =>
                  setState(() => _expandedId = expanded ? null : checkpoint.id),
              trailing: _busyId == checkpoint.id
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () => _restore(checkpoint),
                      child: const Text('Restore'),
                    ),
            ),
            if (expanded) _CheckpointDiff(checkpoint: checkpoint),
          ],
        );
      },
    );
  }

  String _reasonLabel(CheckpointReason reason) => switch (reason) {
    CheckpointReason.turn => 'Turn',
    CheckpointReason.safety => 'Before restore',
    CheckpointReason.manual => 'Checkpoint',
  };

  Future<void> _restore(Checkpoint checkpoint, {bool confirm = false}) async {
    setState(() => _busyId = checkpoint.id);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final outcome = await ref
          .read(checkpointServiceProvider)
          .restore(checkpoint, confirm: confirm);
      ref.read(checkpointsRevisionProvider.notifier).bump();
      // The service's own sentence, not a second one written here.
      messenger?.showSnackBar(
        SnackBar(content: Text(restoreOutcomeMessage(outcome))),
      );
    } on CheckpointConflict catch (conflict) {
      if (!mounted) return;
      final proceed = await _askToOverwrite(conflict);
      if (proceed) {
        await _restore(checkpoint, confirm: true);
        return;
      }
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// The refusal, in the service's words.
  ///
  /// Not a sentence of its own: [checkpointRestoreRefusal] is the function
  /// `restore` refuses on, so what is shown here *is* the rule that was
  /// applied — including the half of an undo we cannot do
  /// ([kRestoreLeavesTheConversation]), which is the reason this dialog was
  /// wrong before it was long.
  Future<bool> _askToOverwrite(CheckpointConflict conflict) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard newer changes?'),
        content: SingleChildScrollView(child: Text(conflict.message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore anyway'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }
}

class _CheckpointDiff extends ConsumerWidget {
  const _CheckpointDiff({required this.checkpoint});

  final Checkpoint checkpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `Colors.green.shade700` / `.red.shade700` were the last `.shadeNNN` in
    // `lib/`, and brightness-blind: both stayed dark-on-dark on the dark ramp.
    final semantic = SemanticColors.of(context);
    return FutureBuilder<String>(
      future: ref.read(checkpointServiceProvider).diffOf(checkpoint),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text('${snapshot.error}', style: theme.textTheme.bodySmall),
          );
        }
        final diff = snapshot.data;
        if (diff == null) {
          return const Padding(
            padding: EdgeInsets.all(Insets.md),
            child: LinearProgressIndicator(),
          );
        }
        if (diff.trim().isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text('Nothing changed.', style: theme.textTheme.bodySmall),
          );
        }
        return Container(
          width: double.infinity,
          color: theme.colorScheme.surfaceContainerLowest,
          padding: const EdgeInsets.all(Insets.sm),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in parseUnifiedDiff(diff))
                    Text(
                      line.text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: kMonoFamily,
                        color: switch (line.kind) {
                          DiffLineKind.added => semantic.diffAdded,
                          DiffLineKind.removed => semantic.diffRemoved,
                          DiffLineKind.meta || DiffLineKind.hunk =>
                            theme.colorScheme.onSurfaceVariant,
                          DiffLineKind.context => null,
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
