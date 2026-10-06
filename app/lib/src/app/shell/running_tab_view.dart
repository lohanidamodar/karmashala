import 'dart:async';

import 'package:agent_cli/read.dart' show BackgroundRunState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/dialogs.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/browser/application/browser_pane_controller.dart';
import '../../features/environments/application/environment_providers.dart';
import '../../features/environments/application/environments_controller.dart';
import '../../features/git/application/remote_links.dart'
    show openExternalUrlProvider;
import '../../features/running/application/running_providers.dart';
import '../../features/running/domain/port_label.dart';
import '../../features/running/domain/running_groups.dart';
import '../../features/sessions/application/background_runs_providers.dart';
import '../../features/settings/presentation/settings_catalog.dart';
import 'phone_routes.dart';
import 'side_panel_state.dart';
import 'workbench_tabs.dart' show openSettingsTab;

/// **The Running tab**: everything Karmashala runs — its server, each pane's
/// processes with the ports they listen on, background runs and device
/// mirroring — by machine. Read only while it is on screen.
class RunningTabView extends ConsumerStatefulWidget {
  const RunningTabView({super.key});

  /// How often it reads again while open. Each read is two OS listings.
  static const Duration refreshInterval = Duration(seconds: 10);

  @override
  ConsumerState<RunningTabView> createState() => _RunningTabViewState();
}

class _RunningTabViewState extends ConsumerState<RunningTabView> {
  Timer? _ticker;
  AppLifecycleListener? _lifecycle;

  void _refresh() {
    if (mounted) unawaited(ref.read(runningProvider.notifier).refresh());
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _ticker = Timer.periodic(RunningTabView.refreshInterval, (_) => _refresh());
    // Coming back to the window is when what runs has most likely moved.
    _lifecycle = AppLifecycleListener(onResume: _refresh, onShow: _refresh);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(runningProvider);
    final filter = ref.watch(runningFilterProvider);
    final localId = ref.watch(localEnvironmentProvider)?.id ?? 'local';
    final reading = snapshot.reading;
    return PaneScaffold(
      title: 'Running',
      icon: AppIcons.listMagnifyingGlass,
      actions: [
        if (snapshot.loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Insets.sm),
            child: InlineSpinner(semanticsLabel: 'Reading what runs'),
          ),
        IconButton(
          key: const ValueKey('running-refresh'),
          tooltip: 'Refresh',
          icon: const Icon(AppIcons.arrowClockwise),
          onPressed: _refresh,
        ),
      ],
      body: reading == null
          ? Center(
              child: snapshot.error != null
                  ? _Muted('Could not read what runs: ${snapshot.error}')
                  : const InlineSpinner(semanticsLabel: 'Reading what runs'),
            )
          : _RunningBody(
              reading: reading,
              filter: filter,
              localEnvironmentId: localId,
              error: snapshot.error,
            ),
    );
  }
}

class _RunningBody extends ConsumerWidget {
  const _RunningBody({
    required this.reading,
    required this.filter,
    required this.localEnvironmentId,
    this.error,
  });

  final RunningReading reading;
  final RunningFilter filter;
  final String localEnvironmentId;
  final String? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final environments = ref.watch(environmentsControllerProvider);
    String label(String id) => id == localEnvironmentId
        ? 'This machine'
        : environments.where((e) => e.id == id).firstOrNull?.name ?? id;
    final everyMachine = groupByMachine(
      reading,
      localEnvironmentId: localEnvironmentId,
    ).map((m) => m.environmentId).toList();
    final machines = groupByMachine(
      reading,
      localEnvironmentId: localEnvironmentId,
      environmentId: filter.environmentId,
      sessionId: filter.sessionId,
    );
    final facts = ref.watch(portFactsProvider);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView(
          padding: const EdgeInsets.all(Insets.md),
          children: [
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String?>(
                  key: const ValueKey('running-machine-filter'),
                  value: everyMachine.contains(filter.environmentId)
                      ? filter.environmentId
                      : null,
                  onChanged: (id) =>
                      ref.read(runningFilterProvider.notifier).machine(id),
                  items: [
                    const DropdownMenuItem(child: Text('All machines')),
                    for (final id in everyMachine)
                      DropdownMenuItem(value: id, child: Text(label(id))),
                  ],
                ),
                if (filter.sessionId case final sessionId?)
                  InputChip(
                    key: const ValueKey('running-session-filter'),
                    label: Text(
                      'One session: ${_sessionTitle(reading, sessionId)}',
                    ),
                    onDeleted: () =>
                        ref.read(runningFilterProvider.notifier).session(null),
                  ),
                _Muted('Read ${_clock(reading.checkedAt.toLocal())}'),
              ],
            ),
            if (error != null) _Muted('The last read failed: $error'),
            if (machines.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: Insets.lg),
                child: _Muted('Nothing Karmashala started is running here.'),
              ),
            for (final machine in machines)
              _MachineSection(
                key: ValueKey('running-machine-${machine.environmentId}'),
                label: label(machine.environmentId),
                machine: machine,
                facts: facts,
              ),
          ],
        ),
      ),
    );
  }

  static String _sessionTitle(RunningReading reading, String sessionId) =>
      reading.processes
          .where((p) => p.agentSessionId == sessionId)
          .firstOrNull
          ?.title ??
      sessionId;

  static String _clock(DateTime at) =>
      '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}:'
      '${at.second.toString().padLeft(2, '0')}';
}

class _MachineSection extends StatelessWidget {
  const _MachineSection({
    required this.label,
    required this.machine,
    required this.facts,
    super.key,
  });

  final String label;
  final RunningMachine machine;
  final PortFacts facts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final server = machine.server;
    return Padding(
      padding: const EdgeInsets.only(top: Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const Divider(),
          if (server != null && server.pid > 0) _ServerCard(server: server),
          for (final pane in machine.panes) _PaneCard(pane: pane, facts: facts),
          if (machine.devices.isNotEmpty) ...[
            _Heading('Device mirroring'),
            for (final process in machine.devices)
              _ProcessRow(process: process, facts: facts, owner: 'adb'),
          ],
          for (final note in machine.notes) _Muted(note.text),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Insets.md, bottom: Insets.xs),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// The server: its pid and what it listens on, and where it is managed —
/// never stopped from here.
class _ServerCard extends ConsumerWidget {
  const _ServerCard({required this.server});

  final RunningProcess server;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Heading('Karmashala server'),
      // A Wrap: at phone width the way to Settings goes under the pid.
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Insets.sm,
        children: [
          Text('${server.name ?? 'Server'} · pid ${server.pid}'),
          TextButton(
            key: const ValueKey('running-server-settings'),
            onPressed: () =>
                openSettingsTab(ref, section: SettingsSectionId.server),
            child: const Text('Manage in Settings → Server'),
          ),
        ],
      ),
      for (final port in server.ports)
        _PortRow(
          port: port,
          label: PortLabel(port.label ?? 'Server', PortKind.karmashala),
        ),
    ],
  );
}

class _PaneCard extends ConsumerWidget {
  const _PaneCard({required this.pane, required this.facts});

  final RunningPane pane;
  final PortFacts facts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessionId = pane.agentSessionId;
    final runs = sessionId == null
        ? const <SessionBackgroundRun>[]
        : ref
              .watch(sessionBackgroundRunsProvider(sessionId))
              .where((r) => r.run.state == BackgroundRunState.running)
              .toList();
    final owner = pane.title ?? 'a pane';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Heading(sessionId == null ? 'Terminal: $owner' : 'Session: $owner'),
        for (final process in pane.processes)
          _ProcessRow(process: process, facts: facts, owner: owner),
        for (final run in runs)
          Padding(
            padding: const EdgeInsets.only(left: Insets.lg),
            child: _Muted(
              'Background ${run.run.kind.name}: '
              '${run.run.description ?? run.run.id}',
            ),
          ),
      ],
    );
  }
}

/// One process, its ports, and Stop where the server allows it.
class _ProcessRow extends ConsumerWidget {
  const _ProcessRow({
    required this.process,
    required this.facts,
    required this.owner,
  });

  final RunningProcess process;
  final PortFacts facts;
  final String owner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = process.name ?? 'process';
    final indent = process.role == RunningRole.child ? Insets.lg : 0.0;
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  process.pid > 0 ? '$name · pid ${process.pid}' : name,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (process.stoppable)
                TextButton.icon(
                  key: ValueKey('running-stop-${process.pid}'),
                  icon: const Icon(AppIcons.stop),
                  label: const Text('Stop'),
                  onPressed: () => _stop(context, ref, name),
                ),
            ],
          ),
          for (final port in process.ports)
            _PortRow(
              port: port,
              label: labelPort(
                process: process.name,
                port: port.port,
                command: process.command,
                facts: facts,
              ),
            ),
        ],
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
    final refusal = await controller.stop(process.pid);
    if (refusal != null) {
      messenger?.showSnackBar(SnackBar(content: Text(refusal)));
    }
  }
}

/// One port: what it is, and the ways to it.
class _PortRow extends ConsumerWidget {
  const _PortRow({required this.port, required this.label});

  final RunningPort port;
  final PortLabel label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final url = 'http://localhost:${port.port}';
    final phone = ref.watch(phoneShellRouterProvider).current != null;
    final number = port.port;
    return Padding(
      padding: const EdgeInsets.only(left: Insets.lg),
      child: Row(
        children: [
          const Icon(AppIcons.globe, size: Chrome.iconSmall),
          const SizedBox(width: Insets.xs),
          Expanded(
            child: Text(
              ':$number — ${label.name}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (label.isHttp)
            IconButton(
              key: ValueKey('running-open-$number'),
              tooltip: phone
                  ? 'Show in the desktop\'s Browser'
                  : 'Open in the Browser pane',
              icon: const Icon(AppIcons.globe),
              onPressed: () => openPortInBrowserPane(
                ref,
                url,
                messenger: ScaffoldMessenger.maybeOf(context),
              ),
            ),
          // The phone's own browser would reach the phone's localhost.
          if (label.isHttp && !phone)
            IconButton(
              key: ValueKey('running-system-browser-$number'),
              tooltip: 'Open in the system browser',
              icon: const Icon(AppIcons.arrowSquareOut),
              onPressed: () => ref.read(openExternalUrlProvider)(url),
            ),
          IconButton(
            key: ValueKey('running-copy-$number'),
            tooltip: 'Copy URL',
            icon: const Icon(AppIcons.copy),
            onPressed: () => Clipboard.setData(
              ClipboardData(text: label.isHttp ? url : 'localhost:$number'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [url] in the Browser pane. The page is the server machine's
/// browser, so from a phone this asks the server to show it on the desktop.
Future<void> openPortInBrowserPane(
  WidgetRef ref,
  String url, {
  ScaffoldMessengerState? messenger,
}) async {
  final phone = ref.read(phoneShellRouterProvider).current != null;
  if (!phone) {
    ref.read(sidePanelProvider.notifier).show(SidePanelSurface.browser);
  }
  await ref.read(browserPaneControllerProvider.notifier).navigate(url);
  if (phone) {
    messenger?.showSnackBar(
      SnackBar(content: Text('Showing $url in the desktop\'s Browser.')),
    );
  }
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: Insets.xs),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}
