import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:path/path.dart' as p;

import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/util/clock_provider.dart';
import '../../explorer/application/session_context.dart';
import '../../git/presentation/diff_line_tile.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show DataRefused;
import 'package:karmashala_session/resume.dart' show describeAge;
import '../application/agent_rewind_points.dart';
import '../application/checkpoint_providers.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import '../data/checkpoints_data.dart';

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
    final sessionId = ref.watch(panelSessionIdProvider);
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

    final asked = ref.watch(sessionCheckpointsProvider(sessionId));
    final checkpoints = asked.value ?? const [];
    final skipped = ref.watch(checkpointSkipReasonProvider(sessionId));
    final native = _AgentRewindNote(sessionId: sessionId);
    // Not read yet, or unreadable, is not "none yet": that answer would send
    // the user looking for a checkpoint the list simply has not shown.
    if (!asked.hasValue && !asked.hasError) {
      return const Center(
        child: InlineSpinner(
          size: InlineSpinnerSize.medium,
          semanticsLabel: 'Reading checkpoints',
        ),
      );
    }
    if (!asked.hasValue && asked.hasError) {
      return PanePlaceholder(
        message: 'Could not read the checkpoints: ${asked.error}',
        icon: AppIcons.warningCircle,
      );
    }
    if (checkpoints.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: PanePlaceholder(
              message: checkpointsEmptyMessage(skipped),
              icon: AppIcons.clockCounterClockwise,
            ),
          ),
          native,
        ],
      );
    }

    final now = ref.watch(clockProvider).nowUtc();
    final repositories = {
      for (final c in checkpoints)
        (c.repository.environmentId, c.repository.path),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (skipped != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.md,
              Insets.xs,
              Insets.md,
              Insets.xs,
            ),
            child: Text(
              'Not checkpointing right now: $skipped.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        Expanded(
          child: ListView.separated(
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
                      checkpointTitle(checkpoint),
                      style: theme.textTheme.bodyMedium,
                    ),
                    // §19 at the line the reading is on: a turn is only
                    // pickable if you can tell how long ago it was.
                    subtitle: Text(
                      checkpointSummary(
                        checkpoint,
                        now,
                        showRepository: repositories.length > 1,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                    onTap: () => setState(
                      () => _expandedId = expanded ? null : checkpoint.id,
                    ),
                    trailing: _busyId == checkpoint.id
                        ? const InlineSpinner(size: InlineSpinnerSize.medium)
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
          ),
        ),
        native,
      ],
    );
  }

  /// Puts [checkpoint] back — the whole tree, or only [paths] — at the server,
  /// exactly as `checkpoint_restore` does.
  Future<void> _restore(
    Checkpoint checkpoint, {
    bool confirm = false,
    List<String> paths = const [],
  }) async {
    setState(() => _busyId = checkpoint.id);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final outcome = await ref
          .read(checkpointsDataProvider)
          .restore(checkpoint, confirm: confirm, paths: paths);
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
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    } catch (error) {
      messenger?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// **Capture now**, through the server's recorder — the door the MCP tool
  /// uses, so it waits its turn behind the session's own captures.
  Future<void> _captureNow(String sessionId) async {
    setState(() => _capturing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final checkpoint = await ref
          .read(checkpointsDataProvider)
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
    } on DataRefused catch (refusal) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal.message)));
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// The refusal, in the service's words: [checkpointRestoreRefusal] is the
  /// function the server's restore refuses on, so this *is* the rule that
  /// was applied.
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

class _CheckpointDiff extends ConsumerStatefulWidget {
  const _CheckpointDiff({required this.checkpoint});

  final Checkpoint checkpoint;

  /// The most of the panel an expanded diff takes before it scrolls, so the
  /// checkpoints under it stay reachable.
  static const maxHeight = 320.0;

  @override
  ConsumerState<_CheckpointDiff> createState() => _CheckpointDiffState();
}

class _CheckpointDiffState extends ConsumerState<_CheckpointDiff> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = ref.watch(checkpointDiffProvider(widget.checkpoint));
    return diff.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(Insets.md),
        child: LinearProgressIndicator(),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(Insets.md),
        child: Text('$error', style: theme.textTheme.bodySmall),
      ),
      data: (parsed) {
        if (parsed.lines.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(Insets.md),
            child: Text('Nothing changed.', style: theme.textTheme.bodySmall),
          );
        }
        final scaler = MediaQuery.textScalerOf(context);
        final rowHeight = DiffLineTile.lineHeightOf(scaler);
        final height = (parsed.lines.length * rowHeight + 2 * Insets.xs).clamp(
          0.0,
          _CheckpointDiff.maxHeight,
        );
        return Container(
          height: height,
          color: theme.colorScheme.surfaceContainerLowest,
          child: LayoutBuilder(
            builder: (context, box) {
              final width =
                  DiffLineTile.textWidthOf(parsed.widestLine, scaler) +
                  DiffLineTile.leadingExtent;
              // The vertical bar outside the sideways scroll, so it stays on
              // screen however far the code is scrolled.
              return SelectionArea(
                child: Scrollbar(
                  controller: _vertical,
                  notificationPredicate: (n) => n.depth == 1,
                  child: Scrollbar(
                    controller: _horizontal,
                    child: SingleChildScrollView(
                      controller: _horizontal,
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: width < box.maxWidth ? box.maxWidth : width,
                        child: ListView.builder(
                          controller: _vertical,
                          padding: const EdgeInsets.symmetric(
                            vertical: Insets.xs,
                          ),
                          itemExtent: rowHeight,
                          itemCount: parsed.lines.length,
                          itemBuilder: (context, index) =>
                              DiffLineTile(line: parsed.lines[index]),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
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
                fontFamilyFallback: kMonoFallback,
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

/// A row's facts: its turn (when the title is words rather than the number),
/// files, lines, where (when a session spans repositories), and age.
String checkpointSummary(
  Checkpoint checkpoint,
  DateTime now, {
  bool showRepository = false,
}) {
  final count = checkpoint.files.length;
  final turn = checkpoint.turn;
  final parts = <String>[
    if (turn != null && checkpointHeadline(checkpoint) != null) 'Turn $turn',
    '$count file${count == 1 ? '' : 's'}',
  ];
  final added = checkpoint.additions;
  final removed = checkpoint.deletions;
  if (count > 0 && (added != null || removed != null)) {
    parts.add('+${added ?? 0} −${removed ?? 0}');
  }
  if (showRepository) parts.add(p.basename(checkpoint.repository.path));
  parts.add(describeAge(now.difference(checkpoint.createdAt)));
  return parts.join(' · ');
}

/// What an empty panel says: when checkpoints are taken, and — when the
/// recorder knows one — why this session has none.
String checkpointsEmptyMessage(String? skipReason) {
  const when =
      'Each repository this session’s agent works in is checkpointed as '
      'a turn starts and as it ends, whenever its files changed. Capture now '
      'records one on demand.';
  if (skipReason != null) return 'No checkpoints yet: $skipReason.\n\n$when';
  return 'No checkpoints yet. $when\n\nA session has none until it finishes a '
      'turn, when its folder is not a git repository or is on an SSH host, '
      'or when automatic checkpoints are off.';
}

/// What the agent's own undo offers beside these, or `null` when there is
/// nothing to say about it.
String? agentRewindNote(AgentRewind rewind, AgentRewindPoints? points) =>
    switch (rewind) {
      OwnRewindPoints(:final note) => note(points),
      NoOwnUndo(:final note) => note,
      UnknownRewind() => null,
    };

/// The agent-native half of undo, said under the list. Read-only.
class _AgentRewindNote extends ConsumerWidget {
  const _AgentRewindNote({required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rewind = ref.watch(sessionAgentRewindProvider(sessionId));
    final points = rewind is OwnRewindPoints
        ? ref.watch(agentRewindPointsProvider(sessionId)).value
        : null;
    final note = agentRewindNote(rewind, points);
    if (note == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      color: theme.colorScheme.surfaceContainerLow,
      child: Text(note, style: theme.textTheme.bodySmall),
    );
  }
}
