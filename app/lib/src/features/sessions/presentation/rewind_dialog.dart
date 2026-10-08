import 'package:agent_cli/descriptors.dart' show RewindMode;
import 'package:flutter/material.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/karmashala_ui.dart' show InlineSpinner;
import 'package:karmashala_ui/tokens.dart';

import '../application/turn_rewinds.dart';

/// What the person chose: the mode, and whether files changed outside the
/// agent may be discarded.
typedef RewindChoice = ({RewindMode mode, bool confirm});

/// Most outside-changed files named before "and N more".
const int _namedOutside = 5;

/// **"Rewind to before this message"**: the three modes of Claude Code's own
/// `/rewind`, what the chosen one changes, and a warning naming files changed
/// outside the agent since then. Answers null for Cancel.
class RewindDialog extends StatefulWidget {
  const RewindDialog({required this.target, required this.preview, super.key});

  final TurnRewindTarget target;

  /// Asks the server what a mode would change.
  final Future<RewindPreview> Function(RewindMode mode) preview;

  static Future<RewindChoice?> show(
    BuildContext context, {
    required TurnRewindTarget target,
    required Future<RewindPreview> Function(RewindMode mode) preview,
  }) => showDialog<RewindChoice>(
    context: context,
    builder: (_) => RewindDialog(target: target, preview: preview),
  );

  @override
  State<RewindDialog> createState() => _RewindDialogState();
}

class _RewindDialogState extends State<RewindDialog> {
  late RewindMode _mode = widget.target.canRestoreCode
      ? RewindMode.both
      : RewindMode.conversation;

  /// One preview answers every mode: it is asked with the files whenever
  /// they can be restored.
  late final Future<RewindPreview> _preview = widget.preview(
    widget.target.canRestoreCode ? RewindMode.both : RewindMode.conversation,
  );

  static const _noCheckpoint =
      'No checkpoint was taken at this turn, so its files cannot be restored.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return FutureBuilder<RewindPreview>(
      future: _preview,
      builder: (context, snapshot) {
        final preview = snapshot.data;
        final failed = snapshot.hasError;
        final refusals = _mode.restoresCode
            ? preview?.refusals ?? const <String>[]
            : const <String>[];
        final outside = _mode.restoresCode
            ? preview?.outside ?? const <String>[]
            : const <String>[];
        final ready = preview != null && refusals.isEmpty;
        return AlertDialog(
          title: DesktopDialogTitle(
            icon: AppIcons.arrowCounterClockwise,
            title: 'Rewind to before this message',
            subtitle: _quote(widget.target.words),
          ),
          content: BoundedDialogContent(
            width: DialogWidth.regular,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RadioGroup<RewindMode>(
                  groupValue: _mode,
                  onChanged: (mode) {
                    if (mode != null) setState(() => _mode = mode);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final mode in RewindMode.values)
                        RadioListTile<RewindMode>(
                          key: ValueKey('rewind-mode-${mode.name}'),
                          value: mode,
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          enabled:
                              !mode.restoresCode ||
                              widget.target.canRestoreCode,
                          title: Text(mode.label),
                          subtitle:
                              mode.restoresCode && !widget.target.canRestoreCode
                              ? const Text(_noCheckpoint)
                              : null,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Insets.sm),
                if (failed)
                  Text(
                    _why(snapshot.error),
                    key: const ValueKey('rewind-summary'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                else if (preview == null)
                  const Row(
                    children: [
                      InlineSpinner(),
                      SizedBox(width: Insets.sm),
                      Expanded(child: Text('Reading what would change…')),
                    ],
                  )
                else ...[
                  Text(
                    rewindSummary(preview, _mode),
                    key: const ValueKey('rewind-summary'),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (_noteFor(preview) case final note?) ...[
                    const SizedBox(height: Insets.xs),
                    Text(note, style: muted),
                  ],
                ],
                if (outside.isNotEmpty ||
                    (_mode.restoresCode && (preview?.headMoved ?? false))) ...[
                  const SizedBox(height: Insets.sm),
                  _OutsideWarning(
                    files: outside,
                    headMoved: preview?.headMoved ?? false,
                  ),
                ],
                for (final refusal in refusals) ...[
                  const SizedBox(height: Insets.sm),
                  DesktopErrorBanner(refusal),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            DestructiveButton(
              key: const ValueKey('rewind-confirm'),
              onPressed: ready
                  ? () => Navigator.of(
                      context,
                    ).pop((mode: _mode, confirm: outside.isNotEmpty))
                  : null,
              child: const Text('Rewind'),
            ),
          ],
        );
      },
    );
  }

  String? _noteFor(RewindPreview preview) => switch (_mode) {
    RewindMode.code =>
      'The agent keeps the whole conversation and still believes it made '
          'the edits since.',
    _ => preview.note.isEmpty ? null : preview.note,
  };

  static String _quote(String words) {
    final line = words.replaceAll(RegExp(r'\s+'), ' ').trim();
    return line.length <= 120 ? '“$line”' : '“${line.substring(0, 117)}…”';
  }

  static String _why(Object? error) =>
      error is StateError ? error.message : '$error';
}

/// Files changed outside the agent since then — a person's edits, a commit —
/// which the restore discards, named.
class _OutsideWarning extends StatelessWidget {
  const _OutsideWarning({required this.files, required this.headMoved});

  final List<String> files;
  final bool headMoved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final named = files.take(_namedOutside).join(', ');
    final more = files.length - _namedOutside;
    return Container(
      key: const ValueKey('rewind-outside'),
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            AppIcons.warningCircle,
            size: Chrome.icon,
            color: scheme.onTertiaryContainer,
          ),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              [
                if (files.isNotEmpty)
                  'Changed outside the agent since then, and lost by the '
                      'restore: $named${more > 0 ? ', and $more more' : ''}. '
                      'They are saved as a checkpoint first.',
                if (headMoved)
                  'A commit was made since then: the restored files will '
                      'show as changes against it.',
              ].join(' '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
