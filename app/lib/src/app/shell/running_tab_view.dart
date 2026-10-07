import 'dart:async';

import 'package:agent_cli/process.dart' show EnvironmentKind;
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
    // The Stores page's header: under a page that already names it (the
    // phone's More), no second title.
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
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StatusRow(
            reading: reading,
            loading: snapshot.loading,
            onRefresh: _refresh,
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

/// When it was read, how much it found, and Refresh — the Stores page's
/// status row.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.reading,
    required this.loading,
    required this.onRefresh,
  });

  final RunningReading? reading;
  final bool loading;
  final VoidCallback onRefresh;

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
          const SizedBox(width: Insets.sm),
          TextButton.icon(
            key: const ValueKey('running-refresh'),
            onPressed: loading ? null : onRefresh,
            icon: loading
                ? const InlineSpinner(semanticsLabel: 'Reading what runs')
                : const Icon(AppIcons.arrowClockwise),
            label: const Text('Refresh'),
          ),
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
    String label(String id) {
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
    }

    bool isWsl(String id) =>
        kinds[id] == EnvironmentKind.wsl || id.startsWith('wsl:');
    final everyMachine = groupByMachine(
      reading,
      localEnvironmentId: localId,
    ).map((m) => m.environmentId).toList();
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
          machines: everyMachine,
          label: label,
          filter: filter,
          reading: reading,
          compact: compact,
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
              constraints: const BoxConstraints(maxWidth: 1480),
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

/// The machine filter, a filter box for ports and processes, the session a
/// badge opened it on, and when it was read.
class _Header extends ConsumerWidget {
  const _Header({
    required this.machines,
    required this.label,
    required this.filter,
    required this.reading,
    required this.compact,
    required this.onQuery,
  });

  final List<String> machines;
  final MachineLabel label;
  final RunningFilter filter;
  final RunningReading reading;
  final bool compact;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The app's search box, as the Stores picker draws it: the theme's own
    // filled, outlined field.
    final search = SearchField(
      key: const ValueKey('running-search'),
      onChanged: onQuery,
      decoration: const InputDecoration(
        prefixIcon: Icon(AppIcons.magnifyingGlass),
        hintText: 'Filter ports and processes',
        isDense: true,
      ),
    );
    final picked = machines.contains(filter.environmentId)
        ? filter.environmentId
        : null;
    final picker = _MachinePicker(
      machines: machines,
      picked: picked,
      label: label,
      onPick: (id) => ref.read(runningFilterProvider.notifier).machine(id),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            picker,
            const SizedBox(width: Insets.sm),
            if (compact)
              Expanded(child: search)
            else
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: search,
                ),
              ),
          ],
        ),
        if (filter.sessionId case final sessionId?)
          Padding(
            padding: const EdgeInsets.only(top: Insets.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                key: const ValueKey('running-session-filter'),
                label: Text(
                  'One session: ${_sessionTitle(reading, sessionId)}',
                ),
                onDeleted: () =>
                    ref.read(runningFilterProvider.notifier).session(null),
              ),
            ),
          ),
      ],
    );
  }

  static String _sessionTitle(RunningReading reading, String sessionId) =>
      reading.processes
          .where((p) => p.agentSessionId == sessionId)
          .map((p) => p.title)
          .nonNulls
          .firstOrNull ??
      sessionId;
}

/// Which machine the tab shows, as a chip with a menu: the theme's chip
/// surface and outline, not Material's underlined dropdown.
class _MachinePicker extends StatelessWidget {
  const _MachinePicker({
    required this.machines,
    required this.picked,
    required this.label,
    required this.onPick,
  });

  final List<String> machines;
  final String? picked;
  final MachineLabel label;
  final ValueChanged<String?> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = picked == null ? 'All machines' : label(picked!);
    return MenuAnchor(
      menuChildren: [
        for (final id in <String?>[null, ...machines])
          MenuItemButton(
            key: ValueKey('running-machine-${id ?? 'all'}'),
            leadingIcon: Icon(
              id == picked ? AppIcons.check : null,
              size: Chrome.iconAction,
            ),
            onPressed: () => onPick(id),
            child: Text(id == null ? 'All machines' : label(id)),
          ),
      ],
      builder: (context, controller, _) => Semantics(
        button: true,
        label: 'Machine: $name',
        excludeSemantics: true,
        child: Material(
          color: scheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.sm),
            side: BorderSide(color: scheme.outlineVariant),
          ),
          child: InkWell(
            key: const ValueKey('running-machine-filter'),
            borderRadius: BorderRadius.circular(Radii.sm),
            onTap: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32, maxWidth: 220),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    const SizedBox(width: Insets.xs),
                    Icon(
                      AppIcons.caretDown,
                      size: Chrome.iconAction,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
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
