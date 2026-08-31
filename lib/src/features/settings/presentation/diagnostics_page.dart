import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/theme/design_tokens.dart';
import '../../../core/logging/diagnostics_providers.dart';
import '../../../core/logging/log_buffer.dart';
import '../../../core/process/command_runner.dart';
import '../../../core/process/command_runner_providers.dart';
import '../application/settings_controller.dart';
import '../domain/diagnostics_settings.dart';
import 'settings_row.dart';
import 'settings_section.dart';

/// Settings → Diagnostics: the debug-mode switch, and what happens to the log.
///
/// **Why the switch is not just "show me a panel".** `AppLogger.debug` maps to
/// `Logger.fine`, which is below the root logger's normal `INFO` floor — so a
/// toggle that only revealed a panel would reveal an empty one. Turning debug
/// mode on drops the root level to `ALL`; turning it off restores `INFO`.
/// Warnings and errors are recorded either way, which is why the panel has
/// history the moment it is opened.
class DiagnosticsPage extends ConsumerWidget {
  const DiagnosticsPage({super.key});

  /// The buffer sizes offered. Anything is storable; these are the three
  /// answers to "how far back do you need to see".
  static const _bufferSizes = [1000, kDefaultLogBufferCapacity, 20000];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    final diagnostics = ref.watch(diagnosticsProvider);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'DEBUG MODE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSwitchRow(
                label: 'Debug mode',
                help:
                    'Records fine-grained detail and adds a Logs panel to the '
                    'side rail. Detail starts from when you turn it on; '
                    'warnings and errors are always recorded.',
                value: settings.debugMode,
                onChanged: controller.setDebugMode,
              ),
              SettingsRow(
                label: 'Lines kept in memory',
                help:
                    'The tail the Logs panel shows. Older lines are dropped as '
                    'new ones arrive.',
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
        ),
        SettingsSection(
          title: 'LOG FILE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSwitchRow(
                label: 'Write a log file',
                help:
                    'Survives a crash and a restart — the thing to attach to a '
                    'bug report. Tokens, keys and your user name are removed '
                    'before anything is written.',
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
        ),
      ],
    );
  }
}

/// Where the files are, and a button that opens the folder.
///
/// The app support directory is the correct home for them — the same place the
/// database and the IPC socket live — and it is somewhere nobody would ever
/// find, so it is spelled out and there is a button.
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
            'This platform has no file manager Chitragupta can open.',
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
