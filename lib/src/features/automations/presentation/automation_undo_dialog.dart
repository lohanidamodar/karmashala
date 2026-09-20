import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../checkpoints/application/checkpoint_service.dart';
import '../application/automation_undo.dart';
import 'package:karmashala_automations/runs.dart';

/// Taking back what one unattended run did. Files unconditionally; the commits
/// checkbox is disabled with [undoCommitsRefusal]'s reason.
class AutomationUndoDialog extends ConsumerStatefulWidget {
  const AutomationUndoDialog({required this.run, super.key});

  final AutomationRun run;

  static Future<void> show(
    BuildContext context, {
    required AutomationRun run,
  }) => showDialog<void>(
    context: context,
    builder: (_) => AutomationUndoDialog(run: run),
  );

  @override
  ConsumerState<AutomationUndoDialog> createState() =>
      _AutomationUndoDialogState();
}

class _AutomationUndoDialogState extends ConsumerState<AutomationUndoDialog> {
  /// Null while the reading is being taken. Not an empty summary — "we have not
  /// looked yet" and "there is nothing" are different.
  RunCommits? _commits;
  bool _dropCommits = false;
  String? _outcome;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final commits = await ref
        .read(automationUndoProvider)
        .commitsOf(widget.run);
    if (!mounted) return;
    setState(() => _commits = commits);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final commits = _commits;
    final refusal = commits == null ? null : undoCommitsRefusal(commits);

    return AlertDialog(
      title: const DesktopDialogTitle(
        icon: AppIcons.arrowCounterClockwise,
        title: 'Undo this run',
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              commits == null
                  ? 'Reading what this run left on the branch…'
                  : undoFilesLabel(commits),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Insets.xs),
            Text(
              'The base snapshot holds every byte as it stood before the agent '
              'touched anything, so putting the files back changes nothing '
              'outside this machine.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Insets.sm),
            if (commits != null)
              Tooltip(
                message: refusal ?? '',
                child: CheckboxListTile(
                  dense: true,
                  value: _dropCommits && refusal == null,
                  // Shown, disabled and explained — never hidden. A row that
                  // vanished would leave the reader wondering where it went.
                  onChanged: refusal != null
                      ? null
                      : (value) =>
                            setState(() => _dropCommits = value ?? false),
                  title: Text(undoCommitsLabel(commits)),
                  subtitle: refusal == null
                      ? Text(
                          'A history rewrite, so it is off unless you ask: '
                          '${_shortShas(commits.commits)}',
                          style: theme.textTheme.bodySmall,
                        )
                      : Text(refusal, style: theme.textTheme.bodySmall),
                ),
              ),
            if (_outcome != null) ...[
              const SizedBox(height: Insets.sm),
              Text(_outcome!, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        FilledButton(
          onPressed: commits == null || _working ? null : _undo,
          child: const Text('Undo'),
        ),
      ],
    );
  }

  Future<void> _undo() async {
    setState(() => _working = true);
    final undo = ref.read(automationUndoProvider);
    try {
      try {
        await undo.restoreFiles(widget.run);
      } on CheckpointConflict catch (conflict) {
        // The work that was in the way is already a checkpoint of its own, so
        // confirming loses nothing — `CheckpointService`'s rule, not a second.
        if (!mounted) return;
        setState(() => _outcome = conflict.message);
        await undo.restoreFiles(widget.run, confirm: true);
      }
      if (_dropCommits) await undo.dropCommits(widget.run, _commits!);
      if (!mounted) return;
      setState(() {
        _working = false;
        _outcome = _dropCommits
            ? 'The files are back and the branch has been moved to where this '
                  'run started.'
            : 'The files are back as they stood before this run started.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _outcome = '$error';
      });
    }
  }
}

/// The first few short shas and a count of the rest: the list is a checkbox's
/// subtitle, and ninety of them made it taller than the window.
String _shortShas(List<RunCommit> commits, {int shown = 8}) {
  final named = commits.take(shown).map((c) => c.shortSha).join(', ');
  final rest = commits.length - shown;
  return rest > 0 ? '$named and $rest more' : named;
}
