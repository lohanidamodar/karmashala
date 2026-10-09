import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_host_protocol/protocol.dart'
    show kBackupExclusions, kBackupNotCarried;
import 'package:karmashala_ui/picking.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/backup_client.dart';
import 'backup_words.dart';

/// Settings → Data → Back up: one backup now, into a folder picked here, the
/// server's own schedule, and exactly what a backup leaves out.
class DataBackupSection extends ConsumerStatefulWidget {
  const DataBackupSection({super.key});

  @override
  ConsumerState<DataBackupSection> createState() => _DataBackupSectionState();
}

class _DataBackupSectionState extends ConsumerState<DataBackupSection> {
  static const _keepChoices = [3, 7, 14, 30];

  bool _backingUp = false;

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(backupScheduleProvider);
    return SettingsSection(
      title: SettingsAnchor.dataBackup.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Back up now',
            help:
                'One zip of the sessions, settings, artifacts and evidence, '
                'in a folder you choose. Taken while Karmashala runs.',
            control: OutlinedButton(
              key: const ValueKey('data-backup-now'),
              onPressed: _backingUp ? null : _backUpNow,
              child: Text(_backingUp ? 'Backing up…' : 'Back up now…'),
            ),
          ),
          ...switch (schedule) {
            AsyncData(:final value) => _schedule(value),
            AsyncError(:final error) => [
              SettingsNote('Could not read the backup schedule: $error'),
            ],
            _ => [const SettingsNote('Reading the backup schedule…')],
          },
          SettingsNote('Never in a backup:', child: _Lines(kBackupExclusions)),
          SettingsNote(
            'Referred to, not carried:',
            child: _Lines(kBackupNotCarried),
          ),
        ],
      ),
    );
  }

  List<Widget> _schedule(BackupScheduleReading reading) {
    final folder = reading.folder;
    final newest = reading.newest;
    final error = reading.lastError;
    return [
      SettingsRow(
        label: 'Scheduled backups',
        help: 'Made by the server, which checks every hour.',
        control: DropdownButtonFormField<BackupFrequency>(
          key: const ValueKey('data-backup-frequency'),
          initialValue: reading.frequency,
          isExpanded: true,
          items: [
            for (final frequency in BackupFrequency.values)
              DropdownMenuItem(value: frequency, child: Text(frequency.label)),
          ],
          onChanged: (picked) {
            if (picked == null || picked == reading.frequency) return;
            _setSchedule(reading, frequency: picked);
          },
        ),
      ),
      SettingsRow(
        label: 'Keep the newest',
        help: 'Older scheduled backups in the folder are deleted.',
        control: DropdownButtonFormField<int>(
          initialValue: reading.keep,
          isExpanded: true,
          items: [
            for (final keep in {..._keepChoices, reading.keep}.toList()..sort())
              DropdownMenuItem(value: keep, child: Text('$keep backups')),
          ],
          onChanged: (picked) {
            if (picked == null || picked == reading.keep) return;
            _setSchedule(reading, keep: picked);
          },
        ),
      ),
      SettingsRow(
        label: 'Backup folder',
        helpWidget: Text(
          folder ?? 'None chosen yet.',
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
        control: OutlinedButton(
          onPressed: () => _chooseFolder(reading),
          child: const Text('Choose…'),
        ),
      ),
      if (error != null)
        SettingsNote('The last scheduled backup failed: $error')
      else if (newest != null)
        SettingsNote(
          'The newest backup there is from '
          '${describeBackupTime(context, newest)}.',
        ),
    ];
  }

  Future<String?> _pickFolder(String? near) => pickOneDirectory(
    what: 'the folder to keep backups in',
    context: context,
    startNear: near,
    confirmButtonText: 'Use this folder',
  );

  Future<void> _backUpNow() async {
    final current = ref.read(backupScheduleProvider).value;
    final folder = await _pickFolder(current?.folder);
    if (folder == null || !mounted) return;
    setState(() => _backingUp = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final written = await ref.read(backupClientProvider).create(folder);
      messenger?.showSnackBar(
        SnackBar(content: Text('Backed up to ${written.path}')),
      );
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not back up: ${_reason(error)}')),
      );
    } finally {
      if (mounted) {
        setState(() => _backingUp = false);
        ref.invalidate(backupScheduleProvider);
      }
    }
  }

  Future<void> _chooseFolder(BackupScheduleReading reading) async {
    final folder = await _pickFolder(reading.folder);
    if (folder == null || !mounted) return;
    await _setSchedule(reading, folder: folder);
  }

  Future<void> _setSchedule(
    BackupScheduleReading reading, {
    BackupFrequency? frequency,
    int? keep,
    String? folder,
  }) async {
    var chosen = folder ?? reading.folder;
    final next = frequency ?? reading.frequency;
    // A schedule with nowhere to write asks where first.
    if (next != BackupFrequency.off && chosen == null) {
      chosen = await _pickFolder(null);
      if (chosen == null || !mounted) {
        ref.invalidate(backupScheduleProvider);
        return;
      }
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await ref
          .read(backupClientProvider)
          .setSchedule(
            frequency: next,
            keep: keep ?? reading.keep,
            folder: chosen,
          );
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text('Could not set the schedule: ${_reason(error)}'),
        ),
      );
    }
    if (mounted) ref.invalidate(backupScheduleProvider);
  }

  static String _reason(Object error) =>
      error is StateError ? error.message : '$error';
}

/// [lines] as a short list under a note.
class _Lines extends StatelessWidget {
  const _Lines(this.lines);

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.xxs),
              child: Text('• $line', style: style),
            ),
        ],
      ),
    );
  }
}
