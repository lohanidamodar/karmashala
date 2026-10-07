import 'package:agent_cli/process.dart'
    show EnvironmentKind, ExecutionEnvironment;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environment_providers.dart';
import '../../environments/application/environments_controller.dart';
import '../../flutter_apps/application/attached_apps.dart';
import '../../terminal/data/terminals_client.dart';
import '../domain/port_label.dart';

/// The Running tab's last look, and whether one is under way. Nothing reads
/// on its own: the tab asks while it is open, and the dev-server menu when it
/// opens.
class RunningSnapshot {
  const RunningSnapshot({this.reading, this.error, this.loading = false});

  final RunningReading? reading;
  final String? error;
  final bool loading;
}

class RunningController extends Notifier<RunningSnapshot> {
  @override
  RunningSnapshot build() => const RunningSnapshot();

  TerminalsClient get _client => ref.read(terminalsClientProvider);

  /// Reads again. Concurrent asks share the one in flight.
  Future<void> refresh() {
    return _inFlight ??= _read().whenComplete(() => _inFlight = null);
  }

  Future<void>? _inFlight;

  Future<void> _read() async {
    state = RunningSnapshot(
      reading: state.reading,
      error: state.error,
      loading: true,
    );
    try {
      RunningReading reading;
      try {
        reading = await _client.running();
      } on TerminalRefused catch (refusal) {
        // An older server: its listening ports are all it can say.
        if (!refusal.message.contains('no data request is called')) rethrow;
        reading = _fromPorts(await _client.listeningPorts());
      }
      if (!ref.mounted) return;
      state = RunningSnapshot(reading: reading);
    } on Object catch (error) {
      if (!ref.mounted) return;
      state = RunningSnapshot(reading: state.reading, error: '$error');
    }
  }

  /// Stops [process], on the machine its pid is from; the refusal's words
  /// when the server would not.
  Future<String?> stop(RunningProcess process) async {
    try {
      await _client.stopProcess(process.pid, machine: process.pidMachine);
    } on Object catch (error) {
      return '$error';
    }
    await refresh();
    return null;
  }

  /// An older server's answer: only the ports under panes, and nothing it
  /// would stop.
  static RunningReading _fromPorts(ListeningPortsReading ports) =>
      RunningReading(
        serverPid: 0,
        checkedAt: ports.checkedAt,
        processes: [
          for (final port in ports.ports)
            RunningProcess(
              pid: port.pid,
              parent: 0,
              role: RunningRole.child,
              name: port.process,
              paneId: port.paneId,
              terminalSessionId: port.terminalSessionId,
              title: port.title,
              agentSessionId: port.agentSessionId,
              ports: [RunningPort(port: port.port, address: port.address)],
            ),
        ],
        notes: [
          const RunningNote(
            'This server is older than this app: only ports under panes are '
            'listed, and nothing can be stopped from here.',
          ),
          for (final line in ports.unread) RunningNote(line),
        ],
      );
}

final runningProvider = NotifierProvider<RunningController, RunningSnapshot>(
  RunningController.new,
);

/// What the Running tab shows: one machine or all (null), and one session or
/// all (null) — a session bar's ports badge opens it on its session.
class RunningFilter {
  const RunningFilter({this.environmentId, this.sessionId});

  final String? environmentId;
  final String? sessionId;
}

class RunningFilterController extends Notifier<RunningFilter> {
  @override
  RunningFilter build() => const RunningFilter();

  void machine(String? environmentId) => state = RunningFilter(
    environmentId: environmentId,
    sessionId: state.sessionId,
  );

  void session(String? sessionId) => state = RunningFilter(
    environmentId: state.environmentId,
    sessionId: sessionId,
  );
}

final runningFilterProvider =
    NotifierProvider<RunningFilterController, RunningFilter>(
      RunningFilterController.new,
    );

/// How the Running tab names a machine: `This machine`, `WSL · archlinux`.
typedef MachineLabel = String Function(String environmentId);

/// The machines the Running tab names, and which of them are WSL.
class RunningMachines {
  const RunningMachines(this._environments, this.localId);

  final List<ExecutionEnvironment> _environments;

  /// This machine's environment id.
  final String localId;

  String label(String id) {
    if (id == localId) return 'This machine';
    final environment = _environments.where((e) => e.id == id).firstOrNull;
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
      _environments.where((e) => e.id == id).firstOrNull?.kind ==
          EnvironmentKind.wsl ||
      id.startsWith('wsl:');
}

final runningMachinesProvider = Provider<RunningMachines>(
  (ref) => RunningMachines(
    ref.watch(environmentsControllerProvider),
    ref.watch(localEnvironmentProvider)?.id ?? 'local',
  ),
);

/// The ports the app already knows by what they are: each found Flutter app's
/// VM service.
final portFactsProvider = Provider<PortFacts>((ref) {
  final apps = ref.watch(attachedAppsProvider).apps;
  return PortFacts(
    vmServicePorts: {
      for (final app in apps)
        if (app.uri.hasPort) app.uri.port,
    },
  );
});
