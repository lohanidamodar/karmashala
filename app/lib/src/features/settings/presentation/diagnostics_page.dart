import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import 'package:karmashala_ui/tokens.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../../../core/logging/memory_census_source.dart';
import 'package:karmashala_core/logging.dart';
import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../terminal/application/terminal_sessions_controller.dart';
import '../application/settings_controller.dart';
import '../domain/diagnostics_settings.dart';
import 'settings_catalog.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Diagnostics → Debug mode.
/// `AppLogger.debug` is `Logger.fine`, below the root's `INFO` floor, so the
/// switch drops the root to `ALL` rather than revealing an empty panel.
class DebugModeSection extends ConsumerWidget {
  const DebugModeSection({super.key});

  /// The buffer sizes offered; anything is storable, these are the three asked.
  static const _bufferSizes = [1000, kDefaultLogBufferCapacity, 20000];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return SettingsSection(
      title: SettingsAnchor.debugMode.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Debug mode',
            help:
                'Records extra detail and adds Logs to the context panel’s '
                'More menu.',
            value: settings.debugMode,
            onChanged: controller.setDebugMode,
          ),
          SettingsRow(
            label: 'Lines kept in memory',
            help: 'How many recent lines Logs keeps.',
            control: DropdownButtonFormField<int>(
              initialValue: _bufferSizes.contains(settings.logBufferSize)
                  ? settings.logBufferSize
                  : kDefaultLogBufferCapacity,
              isExpanded: true,
              items: [
                for (final size in _bufferSizes)
                  DropdownMenuItem(value: size, child: Text('$size lines')),
              ],
              onChanged: (value) =>
                  value == null ? null : controller.setLogBufferSize(value),
            ),
          ),
        ],
      ),
    );
  }
}

/// Settings → Diagnostics → Log file: whether one is written, how much, and
/// where.
class LogFileSection extends ConsumerWidget {
  const LogFileSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final diagnostics = ref.watch(diagnosticsProvider);
    final theme = Theme.of(context);
    return SettingsSection(
      title: SettingsAnchor.logFile.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsSwitchRow(
            label: 'Write a log file',
            help:
                'For bug reports. Tokens, keys and your user name are removed.',
            value: settings.logToFile,
            onChanged: controller.setLogToFile,
          ),
          SettingsRow(
            label: 'What to write',
            control: DropdownButtonFormField<LogVerbosity>(
              initialValue: settings.logVerbosity,
              isExpanded: true,
              items: [
                for (final verbosity in LogVerbosity.values)
                  DropdownMenuItem(
                    value: verbosity,
                    child: Text(verbosity.label),
                  ),
              ],
              onChanged: (value) =>
                  value == null ? null : controller.setLogVerbosity(value),
            ),
          ),
          const _LogFolderRow(),
          if (diagnostics.file?.lastError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                'The last write failed: $error',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Whether terminal scrollback is written as fast as it is produced. Sampled
/// on build, like [WatchSetSection] reads: the dirty set moves on the
/// terminal's hot path, so watching it repaints behind every notification.
class ScrollbackPersistenceSection extends ConsumerWidget {
  const ScrollbackPersistenceSection({super.key});

  static String _age(Duration d) =>
      d.inSeconds >= 1 ? '${d.inSeconds}s' : '${d.inMilliseconds}ms';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Never *creates* the controller: that would restore a whole layout.
    final container = ProviderScope.containerOf(context, listen: false);
    if (!container.exists(terminalSessionsControllerProvider)) {
      return SettingsSection(
        title: SettingsAnchor.scrollbackPersistence.heading,
        child: const SettingsNote('The terminal has not been opened this run.'),
      );
    }
    final telemetry = container
        .read(terminalSessionsControllerProvider.notifier)
        .persistenceTelemetry;
    final write = telemetry.lastWrite;

    return SettingsSection(
      title: SettingsAnchor.scrollbackPersistence.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Panes owing a write',
            help: 'A number that never falls is work not being written.',
            control: SettingsValue(
              label: '${telemetry.dirtyPanes} of ${telemetry.livePanes}',
              mono: true,
            ),
          ),
          SettingsRow(
            label: 'Longest wait',
            help: 'How long the pane waiting longest has owed a write.',
            control: SettingsValue(
              label: telemetry.oldestUnsaved == null
                  ? 'nothing owed'
                  : _age(telemetry.oldestUnsaved!),
              mono: true,
            ),
          ),
          SettingsRow(
            label: 'Last write',
            help: 'Fewer than owed means the pass hit its 8 ms budget.',
            control: SettingsValue(
              label: write == null
                  ? 'not recorded'
                  : '${write.panes} pane(s) in ${_age(write.took)}',
              mono: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the process is holding. Sampled on build, like
/// [ScrollbackPersistenceSection]: the counters move on the terminal's hot
/// path, so watching them would repaint a settings page behind every keystroke.
class MemoryFootprintSection extends ConsumerWidget {
  const MemoryFootprintSection({super.key});

  static String _mib(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MiB';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final census = takeMemoryCensus(
      ProviderScope.containerOf(context, listen: false),
    );
    return SettingsSection(
      title: SettingsAnchor.memoryFootprint.heading,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsRow(
            label: 'Resident memory',
            help: 'The whole process, not only this app\'s Dart objects.',
            control: SettingsValue(
              label:
                  '${_mib(census.residentBytes)} · peak '
                  '${_mib(census.peakResidentBytes)}',
              mono: true,
            ),
          ),
          SettingsRow(
            label: 'Terminal panes',
            help: 'Unparsed panes hold their history as text.',
            control: SettingsValue(
              label:
                  '${census.panes} (${census.detachedPanes} detached, '
                  '${census.unparsedPanes} unparsed)',
              mono: true,
            ),
          ),
          SettingsRow(
            label: 'Scrollback held',
            help: 'Parsed rows, and history held as text.',
            control: SettingsValue(
              label:
                  '${census.scrollbackRows} rows · '
                  '${census.heldScrollbackChars} chars',
              mono: true,
            ),
          ),
          SettingsRow(
            label: 'Sessions watched',
            help: 'Sessions with a status, and log lines in memory.',
            control: SettingsValue(
              label:
                  '${census.watchedSessions} · ${census.logLinesHeld} log lines',
              mono: true,
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the files are, and a button that opens the folder: app support is the
/// right home and one nobody would find.
class _LogFolderRow extends ConsumerWidget {
  const _LogFolderRow();

  Future<void> _reveal(
    BuildContext context,
    WidgetRef ref,
    Directory dir,
  ) async {
    final manager = HostFileManager.forHost();
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (manager == null) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text(
            'This platform has no file manager Karmashala can open.',
          ),
        ),
      );
      return;
    }
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      await ref
          .read(hostCommandRunnerProvider)
          .run(RevealInFileManager.requestFor(manager, dir.path));
    } on CommandException catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not open the folder: ${error.message}')),
      );
    } on FileSystemException catch (error) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not open the folder: ${error.message}')),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final directory = ref.watch(logDirectoryProvider).asData?.value;
    return SettingsRow(
      label: 'Folder',
      help: directory?.path ?? 'Resolving…',
      control: OutlinedButton(
        onPressed: directory == null
            ? null
            : () => _reveal(context, ref, directory),
        child: const Text('Open log folder'),
      ),
    );
  }
}
