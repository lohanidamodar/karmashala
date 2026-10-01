import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/primitives.dart';

import '../../terminal/data/terminals_client.dart';
import '../application/browser_pane_controller.dart';

/// Lists the ports Karmashala's panes have started listening on, read when
/// the menu opens — nothing polls — and opens one in the browser pane.
class DevServerMenuButton extends ConsumerStatefulWidget {
  const DevServerMenuButton({this.enabled = true, super.key});

  final bool enabled;

  @override
  ConsumerState<DevServerMenuButton> createState() =>
      _DevServerMenuButtonState();
}

class _DevServerMenuButtonState extends ConsumerState<DevServerMenuButton> {
  Future<ListeningPortsReading>? _reading;

  void _read() => setState(
    () => _reading = ref.read(terminalsClientProvider).listeningPorts(),
  );

  @override
  Widget build(BuildContext context) => MenuAnchor(
    onOpen: _read,
    menuChildren: [
      FutureBuilder<ListeningPortsReading>(
        future: _reading,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(12),
              child: InlineSpinner(semanticsLabel: 'Looking for dev servers'),
            );
          }
          if (snapshot.error case final error?) {
            return _Note('Could not look: $error');
          }
          final reading = snapshot.data!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (reading.ports.isEmpty)
                const _Note('Nothing started in a pane is listening.'),
              for (final port in reading.ports)
                MenuItemButton(
                  leadingIcon: const Icon(AppIcons.globe, size: 16),
                  onPressed: () => ref
                      .read(browserPaneControllerProvider.notifier)
                      .navigate(port.url),
                  child: Text(
                    'localhost:${port.port} — ${port.title}'
                    '${port.process == null ? '' : ' (${port.process})'}',
                  ),
                ),
              for (final line in reading.unread) _Note(line),
            ],
          );
        },
      ),
    ],
    builder: (context, controller, _) => IconButton(
      tooltip: 'Dev servers started in Karmashala\'s panes',
      icon: const Icon(AppIcons.listMagnifyingGlass),
      onPressed: !widget.enabled
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
