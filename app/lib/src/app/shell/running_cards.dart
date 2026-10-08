import 'package:agent_cli/read.dart' show BackgroundRunState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/menus.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/agents/presentation/agent_logo.dart';
import '../../features/git/application/remote_links.dart'
    show openExternalUrlProvider;
import '../../features/running/application/running_providers.dart';
import '../../features/running/domain/port_label.dart';
import '../../features/running/domain/running_board.dart';
import '../../features/sessions/application/background_runs_providers.dart';
import '../../features/sessions/application/session_agent_providers.dart';
import '../../features/settings/presentation/settings_catalog.dart';
import 'phone_routes.dart';
import 'running_tab_view.dart' show openPortInBrowserPane;
import 'workbench_tabs.dart' show openSettingsTab;

part 'running_cards/port_card.dart';
part 'running_cards/session_card.dart';

/// A section's heading: its name and how many it holds.
class RunningSectionHeading extends StatelessWidget {
  const RunningSectionHeading(this.text, {this.count, super.key});

  final String text;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.sm),
      child: Semantics(
        header: true,
        child: Text.rich(
          TextSpan(
            text: text,
            children: [
              if (count case final count?)
                TextSpan(
                  text: '  $count',
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
          style: theme.textTheme.titleSmall,
        ),
      ),
    );
  }
}

/// Quiet words: an empty state, a time, a count.
class RunningMuted extends StatelessWidget {
  const RunningMuted(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// A sentence about what was not read, put away once read.
class RunningInfoRow extends StatelessWidget {
  const RunningInfoRow({required this.text, this.onDismiss, super.key});

  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: Insets.xs, bottom: Insets.sm),
      padding: const EdgeInsets.fromLTRB(Insets.sm, Insets.xs, 0, Insets.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: Insets.xxs),
            child: Icon(
              AppIcons.info,
              size: Chrome.iconSmall,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: Insets.sm),
          Expanded(child: RunningMuted(text)),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              iconSize: Chrome.iconSmall,
              visualDensity: VisualDensity.compact,
              icon: const Icon(AppIcons.x),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

/// A rounded, outlined surface every card on the tab sits on.
class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.quiet = false});

  final Widget child;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Insets.sm),
      decoration: BoxDecoration(
        color: quiet ? scheme.surface : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

IconData _iconFor(PortKind kind) => switch (kind) {
  PortKind.http => AppIcons.globe,
  PortKind.devTools => AppIcons.globe,
  PortKind.dartVmService => AppIcons.code,
  PortKind.database => AppIcons.stack,
  PortKind.device => AppIcons.deviceMobile,
  PortKind.karmashala => AppIcons.gearSix,
  PortKind.other => AppIcons.linkSimple,
};

/// Opens [url] in the system's browser at once — or, [inPane], in
/// Karmashala's Browser pane. From a phone the desktop's Browser pane shows
/// it, and says so.
Future<void> openRunningUrl(
  WidgetRef ref,
  String url, {
  bool inPane = false,
  ScaffoldMessengerState? messenger,
}) async {
  final phone = ref.read(phoneShellRouterProvider).current != null;
  if (phone || inPane) {
    await openPortInBrowserPane(ref, url, messenger: messenger);
    return;
  }
  await ref.read(openExternalUrlProvider)(url);
}

/// A row about a process a pane started, with Stop on it — right-click,
/// Shift+F10, and a ⋯ [builder] places, shown on hover or focus (always under
/// a thumb). A process that cannot be stopped gets no menu.
class RunningStoppable extends ConsumerWidget {
  const RunningStoppable({
    required this.process,
    required this.owner,
    required this.builder,
    super.key,
  });

  final RunningProcess process;
  final String owner;
  final Widget Function(BuildContext context, Widget? menu) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!process.stoppable) return builder(context, null);
    final name = process.name ?? 'process';
    final label = 'More for $name ${process.pid}';
    List<PopupMenuEntry<String>> items() => [
      PopupMenuItem(
        key: ValueKey('running-stop-${process.pid}'),
        value: 'stop',
        child: Text('Stop $name…'),
      ),
    ];
    return RowContextMenu(
      menuLabel: label,
      itemBuilder: items,
      onSelected: (_) => _stop(context, ref, name),
      builder: (context) => builder(
        context,
        RowMenuButton(
          key: ValueKey('running-more-${process.pid}'),
          tooltip: label,
          itemBuilder: items,
          onSelected: (_) => _stop(context, ref, name),
        ),
      ),
    );
  }

  Future<void> _stop(BuildContext context, WidgetRef ref, String name) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final controller = ref.read(runningProvider.notifier);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Stop $name?'),
        content: Text(
          'Process ${process.pid}, started in "$owner". What it started '
          'stops with it, and nothing it was doing is saved.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          DestructiveButton(
            key: const ValueKey('running-stop-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Stop $name'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final refusal = await controller.stop(process);
    if (refusal != null) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal)));
    }
  }
}

/// The server's own ports, folded into one quiet card.
class RunningServerCard extends ConsumerStatefulWidget {
  const RunningServerCard({required this.server, super.key});

  final RunningProcess server;

  @override
  ConsumerState<RunningServerCard> createState() => _RunningServerCardState();
}

class _RunningServerCardState extends ConsumerState<RunningServerCard> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final server = widget.server;
    final count = server.ports.length;
    return _Surface(
      quiet: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const ValueKey('running-server-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.sm,
              ),
              child: Row(
                children: [
                  const Icon(AppIcons.gearSix, size: Chrome.iconSmall),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      'Karmashala server · $count '
                      '${count == 1 ? 'port' : 'ports'}',
                    ),
                  ),
                  Icon(
                    _open ? AppIcons.caretUp : AppIcons.caretDown,
                    size: Chrome.iconSmall,
                    semanticLabel: _open ? 'Collapse' : 'Expand',
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...[
            for (final port in server.ports)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Insets.xl + Insets.sm,
                  0,
                  Insets.md,
                  Insets.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'localhost:${port.port} — ${port.label ?? 'Server'}',
                      ),
                    ),
                    IconButton(
                      key: ValueKey('running-copy-${port.port}'),
                      tooltip: 'Copy address',
                      iconSize: Chrome.iconSmall,
                      icon: const Icon(AppIcons.copy),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: 'localhost:${port.port}'),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(
                left: Insets.lg,
                bottom: Insets.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('running-server-settings'),
                  onPressed: () =>
                      openSettingsTab(ref, section: SettingsSectionId.server),
                  child: Text(
                    'Manage in Settings → Server · pid ${server.pid}',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
