import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme/app_icons.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../app/widgets/desktop_dialog.dart';
import '../../../core/util/clock_provider.dart';
import '../application/session_changed_files_providers.dart';
import '../domain/session_changed_files.dart';
import '../domain/session_resume.dart' show describeAge;

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
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: switch (async) {
            AsyncValue(hasError: true, :final error) => DesktopErrorBanner(
              'This session’s changes could not be read: $error',
            ),
            AsyncValue(:final value?) => _Body(report: value),
            _ => const Padding(
              padding: EdgeInsets.symmetric(vertical: Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          },
        ),
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
          for (final file in report.files) _FileRow(file: file),
        ],
      ],
    );
  }
}

/// One path, with the change type in words beside it — never carried by colour
/// alone (CLAUDE.md §5).
class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final SessionChangedFile file;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final movedTo = file.movedTo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              file.kind.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              movedTo == null ? file.display : '${file.display} → $movedTo',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
