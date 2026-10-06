
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../../app/shell/logs_tab_view.dart' show LogSource;
import '../../../app/shell/workbench_tabs.dart' show openLogsTab;
import '../../../core/logging/diagnostics_providers.dart';
import '../../settings/presentation/settings_catalog.dart';
import '../../settings/presentation/settings_row.dart';
import '../../settings/presentation/settings_section.dart';
import '../application/server_files.dart';

/// Settings → Server → Log: `<data>/logs/server.log`, the only record a
/// detached server keeps, opened in the host's default app or in the Logs
/// tab. Nothing on a client that hosts no server.
class ServerLogSection extends ConsumerWidget {
  const ServerLogSection({super.key});

  Future<void> _open(BuildContext context, WidgetRef ref, String path) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final failure = await ref.read(serverFilesProvider).openLog(path);
    if (failure != null) {
      messenger?.showSnackBar(SnackBar(content: Text(failure)));
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
              onPressed: () => _open(context, ref, log.path),
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
