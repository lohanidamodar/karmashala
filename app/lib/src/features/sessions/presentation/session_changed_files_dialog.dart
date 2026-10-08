import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/tokens.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/primitives.dart';
import '../../../core/util/clock_provider.dart';
import '../application/session_changed_files_providers.dart';
import 'package:karmashala_session/delivery.dart';
import 'package:karmashala_session/resume.dart' show describeAge;

/// What one session changed, on demand. **Nothing polls it** — a reading costs
/// a call or a transcript pass — and its age is on screen for the same reason.
class SessionChangedFilesDialog extends ConsumerWidget {
  const SessionChangedFilesDialog({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> show(BuildContext context, String sessionId) =>
      showDialog<void>(
        context: context,
        builder: (_) => SessionChangedFilesDialog(sessionId: sessionId),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sessionChangedFilesProvider(sessionId));
    final report = async.asData?.value;

    return AlertDialog(
      title: DesktopDialogTitle(
        icon: AppIcons.gitDiff,
        title: 'Files changed',
        subtitle: report == null
            ? (async.hasError ? 'Could not be read' : 'Reading…')
            : (report.agentName.isEmpty ? null : report.agentName),
      ),
      content: BoundedDialogContent(
        width: DialogWidth.regular,
        child: switch (async) {
          AsyncValue(hasError: true, :final error) => DesktopErrorBanner(
            'This session’s changes could not be read: $error',
          ),
          AsyncValue(:final value?) => _Body(report: value),
          _ => const Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.xl),
            child: Center(child: InlineSpinner(size: InlineSpinnerSize.large)),
          ),
        },
      ),
      actionsPadding: const EdgeInsets.fromLTRB(
        Insets.lg,
        0,
        Insets.lg,
        Insets.md,
      ),
      actions: [
        TextButton(
          onPressed: () =>
              ref.invalidate(sessionChangedFilesProvider(sessionId)),
          child: const Text('Re-read'),
        ),
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.report});

  final SessionChangedFilesReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final caveat = report.caveat;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(report.headline, style: theme.textTheme.bodyMedium),
        const SizedBox(height: Insets.xs),
        Text(
          'Read ${describeAge(ref.read(clockProvider).nowUtc().difference(report.checkedAt))}. '
          'Nothing here is re-read on its own.',
          style: muted,
        ),
        if (caveat != null) ...[
          const SizedBox(height: Insets.sm),
          Text(caveat, style: muted),
        ],
        if (report.files.isNotEmpty) ...[
          const SizedBox(height: Insets.md),
          _FileTable(files: report.files),
        ],
      ],
    );
  }
}

/// Each path with the change type in words beside it — never carried by colour
/// alone (CLAUDE.md §5). The word column is as wide as its longest word at the
/// current text size, so no word breaks and the paths still line up.
class _FileTable extends StatelessWidget {
  const _FileTable({required this.files});

  final List<SessionChangedFile> files;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      children: [
        for (final file in files)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  0,
                  Insets.xxs,
                  Insets.sm,
                  Insets.xxs,
                ),
                child: Text(
                  file.kind.label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Insets.xxs),
                child: SelectableText(switch (file.movedTo) {
                  null => file.display,
                  final movedTo => '${file.display} → $movedTo',
                }, style: theme.textTheme.bodySmall),
              ),
            ],
          ),
      ],
    );
  }
}
