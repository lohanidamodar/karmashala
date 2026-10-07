import 'dart:async';

import 'package:agent_cli/process.dart'
    show EnvironmentKind, ExecutionEnvironment;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_ui/icons.dart';
import 'package:karmashala_ui/panes.dart';
import 'package:karmashala_ui/primitives.dart';
import 'package:karmashala_ui/tokens.dart';

import '../../features/browser/application/browser_pane_controller.dart';
import '../../features/environments/application/environment_providers.dart';
import '../../features/environments/application/environments_controller.dart';
import '../../features/running/application/running_providers.dart';
import '../../features/running/domain/running_board.dart';
import '../../features/running/domain/running_groups.dart';
import '../widgets/adaptive_modal.dart';
import 'phone_routes.dart';
import 'running_cards.dart';
import 'side_panel_state.dart';

/// **The Running tab**: what listens first — each port a link where a browser
/// can open it — then one card per session, on every machine Karmashala runs
/// panes on. Read only while it is on screen.
class RunningTabView extends ConsumerStatefulWidget {
  const RunningTabView({super.key});

  /// How often it reads again while open. Each read is two OS listings, and
  /// one inside each WSL distribution or SSH box with a live pane.
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
    final theme = Theme.of(context);
    final label = runningMachineLabel(
      ref.watch(environmentsControllerProvider),
      localId,
    );
    final machines = reading == null
        ? const <String>[]
        : groupByMachine(
            reading,
            localEnvironmentId: localId,
          ).map((m) => m.environmentId).toList();
    final actions = <Widget>[
      _MachineFilterButton(
        machines: machines,
        picked: machines.contains(filter.environmentId)
            ? filter.environmentId
            : null,
        label: label,
      ),
      if (snapshot.loading)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: Insets.sm),
          child: InlineSpinner(semanticsLabel: 'Reading what runs'),
        )
      else
        IconButton(
          key: const ValueKey('running-refresh'),
          tooltip: 'Refresh',
          icon: const Icon(AppIcons.arrowClockwise),
          onPressed: _refresh,
        ),
    ];
    // The Stores page's header: under a page that already names it (the
    // phone's More), no second title, and its actions move to the status line.
    final untitled = PaneTitleOverride.maybeOf(context) != null;
    return Scaffold(
      appBar: untitled
          ? null
          : AppBar(
              toolbarHeight: 44,
              // A workbench tab: an implied back button would pop the app's
              // route.
              automaticallyImplyLeading: false,
              title: Row(
                children: [
                  Icon(
                    AppIcons.listMagnifyingGlass,
                    color: theme.colorScheme.tertiary,
                  ),
                  const SizedBox(width: Insets.sm),
                  const Flexible(
                    child: Text(
                      'Running',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              actions: [
                ...actions,
                const SizedBox(width: Insets.sm),
              ],
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusLine(
            reading: reading,
            loading: snapshot.loading,
            actions: untitled ? actions : const [],
          ),
          Expanded(child: _bodyOf(snapshot, filter, localId)),
        ],
      ),
    );
  }

  Widget _bodyOf(
    RunningSnapshot snapshot,
    RunningFilter filter,
    String localId,
  ) {
    final reading = snapshot.reading;
    return reading == null
        ? Center(
            child: snapshot.error != null
                ? Padding(
                    padding: const EdgeInsets.all(Insets.lg),
                    child: RunningMuted(
                      'Could not read what runs: ${snapshot.error}',
                    ),
                  )
                : const InlineSpinner(semanticsLabel: 'Reading what runs'),
          )
        : _RunningBody(
            reading: reading,
            filter: filter,
            localEnvironmentId: localId,
            error: snapshot.error,
          );
  }
}

/// How [environments] name a machine: `This machine`, `WSL · archlinux`.
MachineLabel runningMachineLabel(
  List<ExecutionEnvironment> environments,
  String localId,
) => (id) {
  if (id == localId) return 'This machine';
  final environment = environments.where((e) => e.id == id).firstOrNull;
  final name =
      environment?.name ??
      (id.contains(':') ? id.substring(id.indexOf(':') + 1) : id);
  return switch (environment?.kind) {
    EnvironmentKind.wsl => 'WSL · $name',
    EnvironmentKind.ssh => 'SSH · $name',
    _ when id.startsWith('wsl:') => 'WSL · $name',
    _ when id.startsWith('ssh:') => 'SSH · $name',
    _ => name,
  };
};

/// The machine filter, behind a funnel as Overview's filters are: choice
/// chips in a sheet on a phone, a dialog elsewhere.
class _MachineFilterButton extends ConsumerWidget {
  const _MachineFilterButton({
    required this.machines,
    required this.picked,
    required this.label,
  });

  final List<String> machines;
  final String? picked;
  final MachineLabel label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(picked == null ? AppIcons.funnel : AppIcons.funnelFill);
    return IconButton(
      key: const ValueKey('running-machine-filter'),
      tooltip: picked == null ? 'Machines' : 'Machines (${label(picked!)})',
      icon: picked == null
          ? icon
          : Badge.count(
              count: 1,
              backgroundColor: scheme.primary,
              textColor: scheme.onPrimary,
              child: icon,
            ),
      onPressed: () => showAdaptiveModal<void>(
        context: context,
        title: 'Machines',
        builder: (context) => Consumer(
          builder: (context, ref, _) {
            final now = ref.watch(runningFilterProvider).environmentId;
            return Padding(
              padding: const EdgeInsets.all(Insets.lg),
              child: Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  for (final id in <String?>[null, ...machines])
                    ChoiceChip(
                      key: ValueKey('running-machine-${id ?? 'all'}'),
                      label: Text(id == null ? 'All machines' : label(id)),
                      selected: id == now,
                      onSelected: (_) =>
                          ref.read(runningFilterProvider.notifier).machine(id),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// When it was read and how much it found; [actions] too where there is no
/// title bar to hold them.
class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.reading,
    required this.loading,
    required this.actions,
  });

  final RunningReading? reading;
  final bool loading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = reading?.checkedAt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final age = at == null
        ? (loading ? 'Reading what runs…' : 'Not read yet')
        : 'Read ${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
    final ports = reading?.processes.fold<int>(
      0,
      (sum, p) => p.role == RunningRole.server ? sum : sum + p.ports.length,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Insets.lg,
        Insets.xs,
        Insets.sm,
        Insets.xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              ports == null
                  ? age
                  : '$age · $ports ${ports == 1 ? 'port' : 'ports'}',
              key: const ValueKey('running-read-at'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

class _RunningBody extends ConsumerStatefulWidget {
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
  ConsumerState<_RunningBody> createState() => _RunningBodyState();
}

class _RunningBodyState extends ConsumerState<_RunningBody> {
  var _query = '';

  /// Notes put away, by their words: a read that says them again keeps them
  /// put away.
  final _dismissed = <String>{};

  @override
  Widget build(BuildContext context) {
    final reading = widget.reading;
    final filter = widget.filter;
    final localId = widget.localEnvironmentId;
    final environments = ref.watch(environmentsControllerProvider);
    final kinds = {for (final e in environments) e.id: e.kind};
    final label = runningMachineLabel(environments, localId);
    bool isWsl(String id) =>
        kinds[id] == EnvironmentKind.wsl || id.startsWith('wsl:');
    final board = buildRunningBoard(
      reading,
      localEnvironmentId: localId,
      environmentId: filter.environmentId,
      sessionId: filter.sessionId,
      query: _query,
      facts: ref.watch(portFactsProvider),
    );
    final notes = [
      for (final note in board.notes)
        if (!_dismissed.contains(note.text)) note,
    ];
    void dismiss(RunningNote note) => setState(() => _dismissed.add(note.text));
    final sessions = [
      for (final session in board.sessions)
        BoardSession(
          key: session.key,
          paneId: session.paneId,
          title: session.title,
          agentSessionId: session.agentSessionId,
          machine: session.machine,
          processes: session.processes,
          headline: session.headline,
          others: session.others,
          helpers: session.helpers,
          notes: [
            for (final note in session.notes)
              if (!_dismissed.contains(note.text)) note,
          ],
        ),
    ];
    final searching = _query.trim().isNotEmpty;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = WidthClass.of(
          constraints.maxWidth,
          textScaler: MediaQuery.textScalerOf(context),
        );
        final compact = width.isCompact;
        final header = _Header(
          filter: filter,
          reading: reading,
          onQuery: (text) => setState(() => _query = text),
        );
        final listening = <Widget>[
          RunningSectionHeading(
            'Listening',
            count: board.ports.length,
            key: const ValueKey('running-heading-listening'),
          ),
          if (board.ports.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Insets.sm),
              child: RunningMuted(
                searching
                    ? 'No port matches "$_query".'
                    : 'Nothing Karmashala started is listening.',
              ),
            ),
          for (final port in board.ports)
            RunningPortCard(
              key: ValueKey(
                'running-port-${port.machine}-${port.process.pid}-'
                '${port.port.port}',
              ),
              port: port,
              machineLabel: label,
              isWsl: isWsl(port.machine),
            ),
          if (board.server case final server? when server.pid > 0)
            RunningServerCard(server: server),
          if (board.unseen.isNotEmpty)
            Padding(
              key: const ValueKey('running-unseen'),
              padding: const EdgeInsets.only(top: Insets.xs),
              child: RunningMuted(
                'Also listening, by processes this user cannot see: '
                '${board.unseen.map((p) => '${p.port.port} (${label(p.machine)})').join(', ')}.',
              ),
            ),
        ];
        final running = <Widget>[
          RunningSectionHeading(
            'Sessions',
            count: sessions.length,
            key: const ValueKey('running-heading-sessions'),
          ),
          for (final note in notes)
            RunningInfoRow(text: note.text, onDismiss: () => dismiss(note)),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: RunningMuted(
                searching
                    ? 'No process matches "$_query".'
                    : 'No session has a process running.',
              ),
            ),
          for (final session in sessions)
            RunningSessionCard(
              key: ValueKey('running-card-${session.key}'),
              session: session,
              machineLabel: label,
              initiallyOpen: !compact,
              onDismissNote: dismiss,
            ),
          if (board.devices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Insets.xs),
              child: RunningMuted(
                'Device mirroring: '
                '${board.devices.map((d) => d.name ?? 'process').join(', ')}',
              ),
            ),
        ];
        final padding = EdgeInsets.symmetric(
          horizontal: compact ? Insets.lg : Insets.xl,
          vertical: Insets.md,
        );
        final failed = widget.error == null
            ? null
            : RunningMuted('The last read failed: ${widget.error}');
        if (!width.isExpanded) {
          return ListView(
            padding: padding,
            children: [header, ?failed, ...listening, ...running],
          );
        }
        return SingleChildScrollView(
          padding: padding,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              // Two readable columns side by side, and no wider.
              constraints: const BoxConstraints(
                maxWidth: Chrome.readableWidth * 2,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  ?failed,
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: listening,
                        ),
                      ),
                      const SizedBox(width: Insets.xl),
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: running,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The filter box for ports and processes, and the session a badge opened the
/// tab on.
class _Header extends ConsumerWidget {
  const _Header({
    required this.filter,
    required this.reading,
    required this.onQuery,
  });

  final RunningFilter filter;
  final RunningReading reading;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SearchField(
        key: const ValueKey('running-search'),
        onChanged: onQuery,
        decoration: const InputDecoration(
          prefixIcon: Icon(AppIcons.magnifyingGlass),
          hintText: 'Filter ports and processes',
          isDense: true,
        ),
      ),
      if (filter.sessionId case final sessionId?)
        Padding(
          padding: const EdgeInsets.only(top: Insets.sm),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              key: const ValueKey('running-session-filter'),
              label: Text('One session: ${_sessionTitle(reading, sessionId)}'),
              selected: true,
              onSelected: (_) =>
                  ref.read(runningFilterProvider.notifier).session(null),
            ),
          ),
        ),
    ],
  );

  static String _sessionTitle(RunningReading reading, String sessionId) =>
      reading.processes
          .where((p) => p.agentSessionId == sessionId)
          .map((p) => p.title)
          .nonNulls
          .firstOrNull ??
      sessionId;
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
