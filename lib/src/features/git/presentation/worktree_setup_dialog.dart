import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/design_tokens.dart';
import '../domain/worktree_setup.dart';

/// Writes one checkout's worktree setup: the command, and the gitignored paths
/// to copy in.
///
/// **What will run is shown before it is saved.** The field takes a line and
/// [splitCommandLine] turns it into argv once, here, with the result drawn
/// underneath as separate tokens — because argv is what is stored and what the
/// pane is handed, and a user who cannot see the split cannot tell that
/// `--message=two words` became two arguments.
///
/// The paths are validated by [worktreeCopyPathRefusal], the *same* function
/// the setup runs, so a path this dialog accepted cannot be refused later for
/// its spelling. There is no "share instead of copy" control, and there is
/// nothing in [WorktreeSetup] for one to write to.
class WorktreeSetupDialog extends ConsumerStatefulWidget {
  const WorktreeSetupDialog({
    required this.checkoutName,
    required this.existing,
    super.key,
  });

  final String checkoutName;
  final WorktreeSetup existing;

  static Future<WorktreeSetup?> show(
    BuildContext context, {
    required String checkoutName,
    required WorktreeSetup existing,
  }) => showDialog<WorktreeSetup>(
    context: context,
    builder: (_) =>
        WorktreeSetupDialog(checkoutName: checkoutName, existing: existing),
  );

  @override
  ConsumerState<WorktreeSetupDialog> createState() => _WorktreeSetupDialogState();
}

class _WorktreeSetupDialogState extends ConsumerState<WorktreeSetupDialog> {
  late final _command = TextEditingController(
    text: joinCommandLine(widget.existing.command),
  );
  late final _paths = TextEditingController(
    text: widget.existing.copyPaths.join('\n'),
  );

  @override
  void initState() {
    super.initState();
    _command.addListener(_rebuild);
    _paths.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _command.dispose();
    _paths.dispose();
    super.dispose();
  }

  List<String> get _argv => splitCommandLine(_command.text);

  /// The typed paths, one per line, blank lines dropped.
  List<String> get _pathLines => [
    for (final line in _paths.text.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// The first refusal among the typed paths, or null when they are all fine.
  String? get _pathRefusal {
    for (final path in _pathLines) {
      final refusal = worktreeCopyPathRefusal(path);
      if (refusal != null) return refusal;
    }
    return null;
  }

  void _save() {
    if (_pathRefusal != null) return;
    Navigator.of(
      context,
    ).pop(WorktreeSetup(command: _argv, copyPaths: _pathLines));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final refusal = _pathRefusal;
    final argv = _argv;
    return AlertDialog(
      title: Text('Worktree setup · ${widget.checkoutName}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Run when a worktree of this checkout is created. The command '
                'opens in its own pane, in the checkout\'s own environment — a '
                'WSL checkout runs it in the distribution, an SSH one on that '
                'host.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: Insets.md),
              TextField(
                controller: _command,
                autofocus: true,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Setup command (optional)',
                  hintText: 'flutter pub get',
                ),
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: theme.textTheme.bodyMedium?.fontSize,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: Insets.xs),
              // What is stored, drawn as what it is. Nothing re-parses this
              // line later: the shell the pane opens is handed these tokens.
              Text(
                argv.isEmpty
                    ? 'Nothing will be run.'
                    : 'Will run: ${argv.map((a) => '[$a]').join(' ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                ),
              ),
              const SizedBox(height: Insets.lg),
              TextField(
                controller: _paths,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: 'Gitignored paths to copy in, one per line',
                  hintText: '.dart_tool\nmacos/Vendor',
                ),
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: theme.textTheme.bodyMedium?.fontSize,
                ),
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'Copied, never shared. Two worktrees pointing one .dart_tool '
                'at the same folder corrupt each other under concurrent '
                'builds, and this app runs agents concurrently — so there is '
                'no link option. A path git tracks is refused rather than '
                'copied over the branch\'s own files.',
                style: theme.textTheme.bodySmall,
              ),
              if (refusal != null) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  refusal,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: refusal == null ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
