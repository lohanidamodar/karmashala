import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_git/git.dart';

/// Writes one checkout's worktree setup. The split argv is drawn under the
/// field, because argv is what is stored and the split is otherwise invisible.
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
                  fontFamilyFallback: kMonoFallback,
                  fontSize: theme.textTheme.bodyMedium?.fontSize,
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: Insets.xs),
              // Nothing re-parses this line later: the pane is handed these
              // tokens.
              Text(
                argv.isEmpty
                    ? 'Nothing will be run.'
                    : 'Will run: ${argv.map((a) => '[$a]').join(' ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: kMonoFamily,
                  fontFamilyFallback: kMonoFallback,
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
                  fontFamilyFallback: kMonoFallback,
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
