import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/logs_tab_view.dart' show LogSource;
import '../../../app/shell/reveal_in_file_manager.dart';
import '../../../app/shell/workbench_tabs.dart' show openLogsTab;
import '../../../core/logging/diagnostics_providers.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';

/// Settings → Server → Log: `<data>/logs/server.log`, the only record a
/// detached server keeps, opened in the host's default app or in the Logs
/// tab. Nothing on a client that hosts no server.
class ServerLogSection extends ConsumerWidget {
  const ServerLogSection({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, File log) async {
    final manager = HostFileManager.forHost();
    final messenger = ScaffoldMessenger.maybeOf(context);
    void say(String message) =>
        messenger?.showSnackBar(SnackBar(content: Text(message)));
    if (manager == null) {
      return say('This platform has no way for Karmashala to open a file.');
    }
    if (!log.existsSync()) {
      return say('The server has not written its log yet.');
    }
    try {
      await ref
          .read(hostCommandRunnerProvider)
          .run(RevealInFileManager.requestFor(manager, log.path));
    } on CommandException catch (error) {
      say('Could not open the server log: ${error.message}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = ref.watch(serverLogFileProvider);
    if (file case AsyncError(:final error)) {
      return SettingsSection(
        title: SettingsAnchor.serverLog.heading,
        child: SettingsNote('Could not find the server\'s log: $error'),
      );
    }
    final log = file.asData?.value;
    if (log == null) return const SizedBox.shrink();
    return SettingsSection(
      title: SettingsAnchor.serverLog.heading,
      child: SettingsRow(
        label: 'Server log',
        help: log.path,
        control: Wrap(
          alignment: WrapAlignment.end,
          spacing: Insets.xs,
          runSpacing: Insets.xs,
          children: [
            OutlinedButton(
              onPressed: () => _open(context, ref, log),
              child: const Text('Open server log'),
            ),
            OutlinedButton(
              onPressed: () => openLogsTab(ref, source: LogSource.server),
              child: const Text('Open in Logs'),
            ),
          ],
        ),
      ),
    );
  }
}
