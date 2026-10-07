import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../running/application/running_providers.dart';
import '../../running/domain/port_label.dart';
import '../../running/domain/running_groups.dart';
import '../application/browser_pane_controller.dart';

/// The http ports Karmashala's processes listen on — the Running tab's
/// reading, taken again when the menu opens; nothing polls — and opens one in
/// the browser pane.
class DevServerMenuButton extends ConsumerWidget {
  const DevServerMenuButton({this.enabled = true, super.key});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MenuAnchor(
    onOpen: () => ref.read(runningProvider.notifier).refresh(),
    menuChildren: [
      Consumer(
        builder: (context, ref, _) {
          final snapshot = ref.watch(runningProvider);
          final reading = snapshot.reading;
          if (reading == null) {
            if (snapshot.error case final error? when !snapshot.loading) {
              return _Note('Could not look: $error');
            }
            return const Padding(
              padding: EdgeInsets.all(12),
              child: InlineSpinner(semanticsLabel: 'Looking for dev servers'),
            );
          }
          final facts = ref.watch(portFactsProvider);
          final ports = [
            for (final owned in allPorts(reading))
              // A box's port is not this machine's localhost.
              if (owned.process.role != RunningRole.server &&
                  owned.port.host == null &&
                  labelPort(
                    process: owned.process.name,
                    port: owned.port.port,
                    command: owned.process.commandLine ?? owned.process.command,
                    facts: facts,
                  ).isHttp)
                owned,
          ];
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (ports.isEmpty)
                const _Note('Nothing started in a pane is listening.'),
              for (final (:process, :port) in ports)
                MenuItemButton(
                  leadingIcon: const Icon(AppIcons.globe),
                  onPressed: () => ref
                      .read(browserPaneControllerProvider.notifier)
                      .navigate('http://localhost:${port.port}'),
                  child: Text(
                    'localhost:${port.port} — ${process.title ?? ''}'
                    '${process.name == null ? '' : ' (${process.name})'}',
                  ),
                ),
              for (final note in reading.notes) _Note(note.text),
            ],
          );
        },
      ),
    ],
    builder: (context, controller, _) => IconButton(
      tooltip: 'Dev servers started in Karmashala\'s panes',
      icon: const Icon(AppIcons.listMagnifyingGlass),
      onPressed: !enabled
          ? null
          : () => controller.isOpen ? controller.close() : controller.open(),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}
