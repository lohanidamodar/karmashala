import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../server/application/server_commands.dart';
import '../../server/presentation/server_command_actions.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/backup_client.dart';
import 'backup_words.dart';

/// Settings → Data → Restore: a backup checked and shown first, then
/// unpacked into a fresh folder by the server and switched to when it
/// restarts, the data it replaces kept beside it.
class DataRestoreSection extends ConsumerStatefulWidget {
  const DataRestoreSection({super.key});

  @override
  ConsumerState<DataRestoreSection> createState() => _DataRestoreSectionState();
}

class _DataRestoreSectionState extends ConsumerState<DataRestoreSection> {
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final reading = ref.watch(backupScheduleProvider).value;
    final last = reading?.lastRestore;
    return SettingsSection(
      title: SettingsAnchor.dataRestore.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Restore from backup',
            help:
                'The backup is checked and shown first. The data it '
                'replaces is kept beside it as data.before-restore-<time>; '
                'the vaults, server.json and paired phones stay as they are.',
            control: OutlinedButton(
              key: const ValueKey('data-restore'),
              onPressed: _working ? null : _restore,
              child: Text(_working ? 'Checking…' : 'Restore from backup…'),
            ),
          ),
          if (reading?.pendingRestore ?? false)
            SettingsNote(
              'A restore is ready. It switches in when the server restarts.',
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.only(top: Insets.xs),
                  child: FilledButton(
                    onPressed: _restart,
                    child: const Text('Restart server'),
                  ),
                ),
              ),
            ),
          if (last != null)
            SettingsNote(
              'Last restored ${describeBackupTime(context, last.at)}, from '
              'a backup of ${describeBackupTime(context, last.backupCreatedAt)}. '
              'The data it replaced is in ${last.before}.',
            ),
        ],
      ),
    );
  }

  Future<void> _restore() async {
    final picked = await pickOneFile(
      what: 'a Karmashala backup',
      context: context,
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Karmashala backup', extensions: ['zip']),
      ],
    );
    if (picked == null || !mounted) return;
    final client = ref.read(backupClientProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _working = true);
    try {
      final inspected = await client.inspect(picked.path);
      if (!mounted) return;
      final confirmed = await showBackupPreview(
        context,
        summary: inspected.summary,
        refusal: inspected.refusal,
      );
      if (!confirmed || !mounted) return;
      final staged = await client.restore(picked.path);
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            staged.schemaFrom < staged.schemaTo
                ? 'Restore ready, brought up to date from schema '
                      'v${staged.schemaFrom}. Restart the server to switch.'
                : 'Restore ready. Restart the server to switch.',
          ),
        ),
      );
      if (mounted) await _restart();
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Could not restore: '
            '${error is StateError ? error.message : '$error'}',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _working = false);
        ref.invalidate(backupScheduleProvider);
      }
    }
  }

  Future<void> _restart() async {
    await runServerCommand(context, ServerCommand.restart);
    if (!mounted) return;
    // Read again only once the link is back, or the page says the server is
    // not running and keeps the staged note.
    await ref.read(serverLinkBackProvider)();
    if (mounted) ref.invalidate(backupScheduleProvider);
  }
}

/// Shows what a backup holds and asks to restore it; with a [refusal] it
/// says why it cannot, and only closes. True when Restore was pressed.
Future<bool> showBackupPreview(
  BuildContext context, {
  required BackupSummary summary,
  String? refusal,
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      void close(bool value) => Navigator.of(dialogContext).pop(value);
      return AlertDialog(
        title: DesktopDialogTitle(
          icon: AppIcons.floppyDisk,
          title: 'Restore this backup?',
          subtitle:
              'Karmashala ${summary.appVersion}, '
              '${describeBackupTime(dialogContext, summary.createdAt)}',
        ),
        content: BoundedDialogContent(
          width: DialogWidth.regular,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (refusal != null) ...[
                DesktopErrorBanner(refusal),
                const SizedBox(height: Insets.md),
              ],
              for (final line in describeBackupContents(summary))
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.xs),
                  child: Text('• $line', style: theme.textTheme.bodyMedium),
                ),
              const SizedBox(height: Insets.sm),
              Text(
                'It was made from ${summary.dataDirectory}. Paths it '
                'records — projects, repositories, SSH keys — are that '
                "machine's; on another machine, sign in to the agents and "
                'GitHub again and fix any path that does not resolve.',
                style: theme.textTheme.bodySmall,
              ),
              if (refusal == null) ...[
                const SizedBox(height: Insets.sm),
                Text(
                  'Restarting the server ends the sessions it runs.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => close(false),
            child: Text(refusal == null ? 'Cancel' : 'Close'),
          ),
          if (refusal == null)
            FilledButton(
              key: const ValueKey('data-restore-confirm'),
              onPressed: () => close(true),
              child: const Text('Restore'),
            ),
        ],
      );
    },
  );
  return answer ?? false;
}
