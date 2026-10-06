
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../explorer/application/bulk_session_delete.dart';
import '../../explorer/presentation/bulk_delete_dialog.dart';
import '../../explorer/presentation/purge_progress_strip.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/server_files.dart';
import '../application/server_storage.dart';

/// Settings → Server → Storage: the database and the tool-image cache as the
/// server reads them, the cache's limits, and old ended sessions to clean up
/// — only when asked.
class ServerStorageSection extends ConsumerWidget {
  const ServerStorageSection({super.key});

  static const _ageChoices = [3, 7, 14, 30, 90];
  static const _capChoices = [64, 128, 256, 512, 1024, 2048];
  static const _sessionAgeChoices = [7, 30, 90, 180];
  static const _timelineChoices = [0, 30, 90, 180, 365];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(serverStorageProvider);
    final settings = ref.watch(settingsControllerProvider);
    return SettingsSection(
      title: SettingsAnchor.serverStorage.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...switch (storage) {
            AsyncData(:final value) => _readings(context, ref, value),
            AsyncError(:final error) => [
              SettingsNote('Could not read the server\'s storage: $error'),
            ],
            _ => [const SettingsNote('Reading the server\'s storage…')],
          },
          SettingsRow(
            label: 'Keep unused tool images for',
            control: _choice(
              value: settings.toolImageMaxAgeDays,
              choices: _ageChoices,
              label: _days,
              onChanged: (days) => _setLimits(context, ref, days: days),
            ),
          ),
          SettingsRow(
            label: 'Tool-image cache cap',
            help: 'Past it, the least recently used go first.',
            control: _choice(
              value: settings.toolImageMaxMegabytes,
              choices: _capChoices,
              label: _megabytes,
              onChanged: (cap) => _setLimits(context, ref, megabytes: cap),
            ),
          ),
          const _OldSessionsRow(),
          SettingsRow(
            label: 'Keep the timeline for',
            help: 'What happened, when: kept apart from the sessions, so '
                'deleting one leaves its history.',
            control: _choice(
              value: settings.activityLogKeepDays,
              choices: _timelineChoices,
              label: (days) => days == 0 ? 'Forever' : _days(days),
              onChanged: ref
                  .read(settingsControllerProvider.notifier)
                  .setActivityLogKeepDays,
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _readings(
    BuildContext context,
    WidgetRef ref,
    ServerStorageReading reading,
  ) {
    final tables = reading.tables;
    return [
      SettingsRow(
        label: 'Database',
        help: tables == null
            ? 'Its tables could not be measured.'
            : [
                for (final table in tables)
                  '${table.name} ${describeBytes(table.bytes)}',
              ].join(' · '),
        control: SettingsValue(label: describeBytes(reading.databaseBytes)),
      ),
      SettingsRow(
        label: 'Tool images',
        help: 'Pictures agents\' tools answered with, kept so a transcript '
            'can show them.',
        control: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: Insets.xs,
          runSpacing: Insets.xs,
          children: [
            SettingsValue(
              label:
                  '${reading.toolImageFiles} '
                  '${reading.toolImageFiles == 1 ? 'file' : 'files'} · '
                  '${describeBytes(reading.toolImageBytes)}',
            ),
            OutlinedButton(
              onPressed: reading.toolImageFiles == 0
                  ? null
                  : () => _clear(context, ref),
              child: const Text('Clear'),
            ),
          ],
        ),
      ),
    ];
  }

  Widget _choice({
    required int value,
    required List<int> choices,
    required String Function(int) label,
    required ValueChanged<int> onChanged,
  }) {
    final all = {...choices, value}.toList()..sort();
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      items: [
        for (final choice in all)
          DropdownMenuItem(value: choice, child: Text(label(choice))),
      ],
      onChanged: (picked) {
        if (picked != null && picked != value) onChanged(picked);
      },
    );
  }

  static String _days(int days) => days == 1 ? '1 day' : '$days days';

  static String _megabytes(int megabytes) => megabytes % 1024 == 0
      ? '${megabytes ~/ 1024} GB'
      : '$megabytes MB';

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Clear the tool-image cache?',
      message:
          'A transcript that showed one of these pictures says it is no '
          'longer kept. Nothing else changes.',
      confirmLabel: 'Clear',
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final removed = await ref
          .read(serverStorageClientProvider)
          .clearToolImages();
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            removed == 1 ? 'Removed 1 image.' : 'Removed $removed images.',
          ),
        ),
      );
    } on Object catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not clear the cache: $error')),
      );
    }
    if (context.mounted) ref.invalidate(serverStorageProvider);
  }

  Future<void> _setLimits(
    BuildContext context,
    WidgetRef ref, {
    int? days,
    int? megabytes,
  }) async {
    await ref.read(toolImageLimitsSetterProvider)(
      days: days,
      megabytes: megabytes,
    );
    if (context.mounted) ref.invalidate(serverStorageProvider);
  }
}

/// How many ended sessions are older than the set age, and Clean up, which
/// asks first and deletes through the bulk delete the Explorer uses.
class _OldSessionsRow extends ConsumerWidget {
  const _OldSessionsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final old = ref.watch(oldEndedSessionsProvider);
    final days = ref.watch(
      settingsControllerProvider.select((s) => s.endedSessionsOlderThanDays),
    );
    final count = old.isEmpty
        ? 'No ended sessions'
        : old.length == 1
        ? '1 ended session'
        : '${old.length} ended sessions';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsRow(
          label: 'Old ended sessions',
          helpWidget: Text(
            '$count started more than ${ServerStorageSection._days(days)} '
            'ago.',
          ),
          control: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Insets.xs,
            runSpacing: Insets.xs,
            children: [
              SizedBox(
                width: 120,
                child: DropdownButtonFormField<int>(
                  initialValue: days,
                  isExpanded: true,
                  items: [
                    for (final choice in {
                      ...ServerStorageSection._sessionAgeChoices,
                      days,
                    }.toList()..sort())
                      DropdownMenuItem(
                        value: choice,
                        child: Text(ServerStorageSection._days(choice)),
                      ),
                  ],
                  onChanged: (picked) {
                    if (picked == null) return;
                    ref
                        .read(settingsControllerProvider.notifier)
                        .setEndedSessionsOlderThanDays(picked);
                  },
                ),
              ),
              OutlinedButton(
                onPressed: old.isEmpty
                    ? null
                    : () => _cleanUp(context, ref, [
                        for (final session in old) session.id,
                      ]),
                child: const Text('Clean up'),
              ),
            ],
          ),
        ),
        const SettingsNote(
          'Only when you press Clean up: nothing here deletes on its own.',
        ),
        const PurgeProgressStrip(),
      ],
    );
  }

  Future<void> _cleanUp(
    BuildContext context,
    WidgetRef ref,
    List<String> ids,
  ) async {
    final bulk = ref.read(sessionBulkDeleteProvider);
    final targets = bulk.resolve(ids);
    if (targets.isEmpty) return;
    final deleteFromCli = await confirmBulkSessionDelete(context, targets);
    if (deleteFromCli == null) return;
    bulk.run(targets, deleteFromCli: deleteFromCli);
  }
}
