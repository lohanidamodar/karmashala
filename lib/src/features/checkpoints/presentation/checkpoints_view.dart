import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/pane_scaffold.dart';
import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import 'package:karmashala_git/git.dart';
import '../../sessions/application/session_ui_providers.dart';
import '../../sessions/domain/session_resume.dart' show describeAge;
import '../application/checkpoint_providers.dart';
import '../application/checkpoint_service.dart';
import '../application/session_checkpoint_recorder.dart';
import '../domain/checkpoint.dart';

/// Which session's checkpoints the panel is describing — the session **on
/// screen**, not the one last clicked in the Explorer.
final checkpointsPanelSessionIdProvider = Provider<String?>(
  (ref) =>
      ref.watch(activePaneSessionIdProvider) ??
      ref.watch(selectedSessionIdProvider),
);

/// The checkpoints of a session, and the way back to one. Nothing polls, and
/// every row carries the age of its capture (§19).
class CheckpointsView extends ConsumerStatefulWidget {
  const CheckpointsView({super.key});

  @override
  ConsumerState<CheckpointsView> createState() => _CheckpointsViewState();
}

class _CheckpointsViewState extends ConsumerState<CheckpointsView> {
  String? _expandedId;
  String? _busyId;
  bool _capturing = false;

  @override
  Widget build(BuildContext context) {
    final sessionId = ref.watch(checkpointsPanelSessionIdProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaneHeader(
          icon: AppIcons.clockCounterClockwise,
          title: 'Checkpoints',
          actions: [
            IconButton(
              tooltip: 'Capture the working tree now',
              icon: const Icon(AppIcons.plusCircle, size: Chrome.iconAction),
              // Disabled rather than absent while a capture is in flight: two `git add -A`
              // runs over one private index is the collision the recorder guards against.
              onPressed: sessionId == null || _capturing
                  ? null
                  : () => _captureNow(sessionId),
            ),
          ],
        ),
        Expanded(child: _list(context, sessionId)),
      ],
    );
  }

  Widget _list(BuildContext context, String? sessionId) {
    final theme = Theme.of(context);
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
            'finishes a turn, and Capture now records one on demand.',
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
            if (expanded) ...[
              for (final file in checkpoint.files)
                _FileRow(
                  path: file.path,
                  onRestore: _busyId == checkpoint.id
                      ? null
                      : () => _restore(checkpoint, paths: [file.path]),
                ),
              _CheckpointDiff(checkpoint: checkpoint),
            ],
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

  /// Puts [checkpoint] back — the whole tree, or only [paths], sent as one
  /// whole-file [HunkSelection] each exactly as `checkpoint_restore` does.
  Future<void> _restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<String> paths = const [],
  }) async {
    setState(() => _busyId = checkpoint.id);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final outcome = await ref
          .read(checkpointServiceProvider)
          .restore(
            checkpoint,
            confirm: confirm,
            selection: [for (final path in paths) HunkSelection(path)],
          );
      ref.read(checkpointsRevisionProvider.notifier).bump();
      // The service's own sentence, not a second one written here.
      messenger?.showSnackBar(
        SnackBar(content: Text(restoreOutcomeMessage(outcome))),
      );
    } on CheckpointConflict catch (conflict) {
      if (!mounted) return;
      final proceed = await _askToOverwrite(conflict);
      if (proceed) {
        await _restore(checkpoint, confirm: true, paths: paths);
        return;
      }
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// **Capture now**, through [SessionCheckpointRecorder] — the door the MCP
  /// tool uses. Going straight to the service skips the guard, revision and record.
  Future<void> _captureNow(String sessionId) async {
    setState(() => _capturing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final checkpoint = await ref
          .read(sessionCheckpointRecorderProvider.notifier)
          .captureNow(sessionId, decidedBy: 'the user');
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            checkpoint == null
                ? kNothingToCapture
                : 'Captured checkpoint ${checkpoint.sequence}.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// The refusal, in the service's words: [checkpointRestoreRefusal] is the
  /// function `restore` refuses on, so this *is* the rule that was applied.
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

/// One file a checkpoint touched, and the safer of the two ways back — the
/// verb somebody wants most of the time, and the one the widget had no way to ask.
class _FileRow extends StatelessWidget {
  const _FileRow({required this.path, required this.onRestore});

  final String path;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: Insets.lg, right: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: kMonoFamily,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Restore this file only',
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              AppIcons.arrowCounterClockwise,
              size: Chrome.iconAction,
            ),
            onPressed: onRestore,
          ),
        ],
      ),
    );
  }
}
