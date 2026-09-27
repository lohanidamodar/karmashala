import 'dart:async';
import 'dart:io';

import 'package:riverpod/riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'package:agent_cli/process.dart';
import '../../../core/process/command_runner_providers.dart';
import '../../../core/util/clock_provider.dart';
import 'package:karmashala_device_pane/ports.dart';
import 'package:karmashala_devices/devices.dart';
import '../../mcp/control_server_status.dart';
import '../../mcp/host_session_mcp.dart';
import '../../mcp/session_mcp.dart';
import 'package:karmashala_mcp/access.dart';
import 'environment_health.dart';
import 'environment_providers.dart';
import 'system_health.dart';

/// Runs the machine checks behind the health panel. **Nothing here runs on a
/// timer**, and the report carries the time it ran — see docs/SETTLED.md.
class SystemHealthService {
  SystemHealthService(this.ref);

  final Ref ref;

  /// Where the checks look for free space. Injected so a test does not need a
  /// platform channel.
  Future<Directory> Function() supportDirectory =
      getApplicationSupportDirectory;

  /// Existence check for a filesystem path, injected for the same reason.
  bool Function(String path) directoryExists = (p) => Directory(p).existsSync();

  /// Reads a small text file, or returns null if it cannot be read.
  String? Function(String path) readTextFile = (p) {
    try {
      return File(p).readAsStringSync();
    } on IOException {
      return null;
    }
  };

  Future<List<SystemCheck>> checkAll() async {
    final environments = ref.read(environmentsDataProvider).getAll();
    final results = await Future.wait([
      _guard(SystemCheckId.mcpBridge, 'MCP bridge', _checkMcpBridge),
      _guard(
        SystemCheckId.controlServer,
        'Agent tools endpoint',
        _checkControlServer,
      ),
      ...environments
          .where((e) => e.kind == EnvironmentKind.wsl)
          .map(
            (environment) => _guard(
              SystemCheckId.wslInterop,
              'WSL → Windows interop (${environment.name})',
              () => _checkWslInterop(environment),
            ),
          ),
      _guard(
        SystemCheckId.androidTooling,
        'Android tooling',
        _checkAndroidTooling,
      ),
      _guard(SystemCheckId.diskSpace, 'Disk space', _checkDiskSpace),
    ]);
    return results;
  }

  /// Runs one check, turning any escape into an honest [HealthLevel.unknown]: a
  /// panel crashed by what it reports on teaches the user nothing either.
  Future<SystemCheck> _guard(
    SystemCheckId id,
    String title,
    Future<SystemCheck> Function() body,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      final check = await body();
      return check.took == null
          ? check.copyWith(title: title, took: stopwatch.elapsed)
          : check.copyWith(title: title);
    } on Object catch (error) {
      return SystemCheck(
        id: id,
        title: title,
        level: HealthLevel.unknown,
        summary: 'Could not be checked.',
        detail: '$error',
        took: stopwatch.elapsed,
      );
    }
  }

  // --- MCP bridge ----------------------------------------------------------

  Future<SystemCheck> _checkMcpBridge() async {
    final result = await ref.read(mcpBridgeProbeProvider).probe();
    return switch (result.verdict) {
      McpBridgeVerdict.answering => SystemCheck(
        id: SystemCheckId.mcpBridge,
        title: 'MCP bridge',
        level: HealthLevel.healthy,
        summary:
            'Answering — the bridge started and finished an MCP initialize '
            'handshake.',
        detail: [?result.path, ?result.detail].join('\n'),
        took: result.took,
      ),
      McpBridgeVerdict.unspawnable => SystemCheck(
        id: SystemCheckId.mcpBridge,
        title: 'MCP bridge',
        level: HealthLevel.failed,
        summary:
            'Present but unspawnable — the file is beside the app and this '
            'machine refused to start it.',
        detail: [?result.path, ?result.detail].join('\n'),
        remedy:
            'A refused spawn is the machine, not the app: security software '
            'holding the file, or a half-written install. If what lost its '
            'tools was a session inside WSL, read the interop row instead — '
            'that is a different spawn with a different fault.',
        took: result.took,
      ),
      McpBridgeVerdict.absent => SystemCheck(
        id: SystemCheckId.mcpBridge,
        title: 'MCP bridge',
        level: HealthLevel.warning,
        summary:
            'Not found — there is no karmashala_mcp beside the app for an '
            'agent to spawn.',
        remedy:
            'Sessions inside WSL then fall back to the WSL switch address for '
            'tools, and where that address is reset they get no Karmashala '
            'tools at all. Compile the bridge next to the app, or reinstall.',
        remedyCommand:
            'dart compile exe packages/mcp_bridge/bin/karmashala_mcp.dart '
            '-o <folder holding the app>/karmashala_mcp',
        took: result.took,
      ),
      McpBridgeVerdict.noHandshake => SystemCheck(
        id: SystemCheckId.mcpBridge,
        title: 'MCP bridge',
        level: HealthLevel.failed,
        summary:
            'Spawned but not answering — the process started and the MCP '
            'initialize handshake did not complete.',
        detail: [?result.path, ?result.detail].join('\n'),
        remedy:
            'A bridge that starts and will not speak MCP is a fault here '
            'rather than on the machine. Settings → Diagnostics has the log.',
        took: result.took,
      ),
    };
  }

  // --- Control server ------------------------------------------------------

  /// Whether the app will answer the bridge it just spawned. **Read, not
  /// probed** — the server records which hardening step failed as it starts.
  Future<SystemCheck> _checkControlServer() async {
    final status = ref.read(controlServerStatusProvider);
    final level = switch (status.transport) {
      PrivilegedRpcTransport.ownerOnlySocket ||
      PrivilegedRpcTransport.loopbackHttp => HealthLevel.healthy,
      PrivilegedRpcTransport.notStarted => HealthLevel.unknown,
      PrivilegedRpcTransport.unavailable => HealthLevel.failed,
      // Read off the host's handshake: whether it published a credential.
      PrivilegedRpcTransport.sessionHost => switch (ref.read(
        sessionMcpProvider,
      )) {
        HostSessionMcp(:final serving) when serving => HealthLevel.healthy,
        _ => HealthLevel.unknown,
      },
    };
    return SystemCheck(
      id: SystemCheckId.controlServer,
      title: 'Agent tools endpoint',
      level: level,
      summary: status.message,
      detail: [
        'Recorded by the control server as it started; nothing was probed '
            'for this row.',
        ?status.failureDetail,
      ].join('\n'),
      remedy: status.failedClosed
          ? 'The app withheld privileged RPC on purpose rather than serving it '
                'unprotected. Agents can still report status, but every '
                'Karmashala tool is off until the owner-only channel can be '
                'made. Restarting the app retries it.'
          : null,
      took: Duration.zero,
    );
  }

  // --- WSL interop ---------------------------------------------------------

  Future<SystemCheck> _checkWslInterop(ExecutionEnvironment environment) async {
    final title = 'WSL → Windows interop (${environment.name})';
    final runner = ref
        .read(commandRunnerFactoryProvider)
        .forEnvironment(environment);
    WslInteropState state;
    String? detail;
    try {
      final result = await runner.run(wslInteropRequest());
      state = parseWslInterop(result.stdout);
      if (state == WslInteropState.unknown) {
        detail = result.stderr.trim().isEmpty
            ? 'sh exited ${result.exitCode} without reporting a handler.'
            : result.stderr.trim();
      }
    } on Object catch (error) {
      state = WslInteropState.unknown;
      detail = '$error';
    }
    return switch (state) {
      WslInteropState.registered => SystemCheck(
        id: SystemCheckId.wslInterop,
        title: title,
        level: HealthLevel.healthy,
        summary:
            'Windows programs run — the interop handler is registered in this '
            'distribution.',
      ),
      WslInteropState.disabled => SystemCheck(
        id: SystemCheckId.wslInterop,
        title: title,
        level: HealthLevel.failed,
        summary:
            'Switched off — the interop handler is registered but disabled, so '
            'no Windows program started here will run.',
        remedy: _interopRemedy,
        remedyCommand: kWslInteropRepairCommand,
      ),
      WslInteropState.missing => SystemCheck(
        id: SystemCheckId.wslInterop,
        title: title,
        level: HealthLevel.failed,
        summary:
            'Gone — no interop handler is registered, so every Windows program '
            'a session here spawns fails with ENOEXEC.',
        remedy: _interopRemedy,
        remedyCommand: kWslInteropRepairCommand,
      ),
      WslInteropState.unknown => SystemCheck(
        id: SystemCheckId.wslInterop,
        title: title,
        level: HealthLevel.unknown,
        summary:
            'Could not be checked — ${environment.name} did not answer, so '
            'nothing is known about interop there.',
        detail: detail,
      ),
    };
  }

  static const String _interopRemedy =
      'This is the machine, not the app, and it takes out everything at once: '
      'the MCP bridge a session here spawns, cmd.exe, and any Windows build '
      'tool. It keeps coming back because WSL\'s own repair lives in '
      'systemd-binfmt.service, which is skipped on every boot where each '
      'binfmt.d directory is empty. The command below registers the handler '
      'now and writes the file that makes that repair run from here on.';

  // --- Android tooling -----------------------------------------------------

  /// Scoped to the host SDK on purpose: a WSL or SSH environment can hold its
  /// own, and one verdict about several installations says nothing.
  Future<SystemCheck> _checkAndroidTooling() async {
    const id = SystemCheckId.androidTooling;
    const title = 'Android tooling';
    final host = localHostEnvironment(ref.read(clockProvider).nowUtc());
    final runner = ref.read(hostCommandRunnerProvider);
    final sdk = await AndroidSdkDiscoveryService(
      runner: runner,
      environment: host,
      // The same rule the pane and the server follow: one adb per machine.
      handSetRoot: ref.read(deviceAndroidSdkPathProvider),
    ).discover();
    if (sdk == null) {
      return const SystemCheck.notChecked(
        id: id,
        title: title,
        reason:
            'No Android SDK on this host, so nothing Android was checked. '
            'Nothing else here depends on one.',
      );
    }
    final adbVersion = await _firstLine(
      runner,
      executableProbeRequest(sdk.adb.path, kAdbVersionFlag),
    );
    if (sdk.emulator == null) {
      return SystemCheck(
        id: id,
        title: title,
        level: HealthLevel.warning,
        summary:
            'adb is here, the emulator package is not, so no AVD on this host '
            'can be booted.',
        detail: [?adbVersion, sdk.root.path].join('\n'),
        remedy: 'Install the "Android Emulator" package from the SDK Manager.',
      );
    }
    final avds = await _listAvds(runner, sdk);
    if (avds.isEmpty) {
      return SystemCheck(
        id: id,
        title: title,
        level: HealthLevel.healthy,
        summary: 'adb and the emulator are here. No AVDs are defined.',
        detail: [?adbVersion, sdk.root.path].join('\n'),
      );
    }
    final statuses = _inspectAvds(avds, sdk);
    final broken = statuses.where((s) => s.missingImage).toList();
    final unchecked = statuses.where((s) => !s.checked).toList();
    if (broken.isEmpty) {
      return SystemCheck(
        id: id,
        title: title,
        level: unchecked.isEmpty ? HealthLevel.healthy : HealthLevel.unknown,
        summary: unchecked.isEmpty
            ? 'adb and the emulator are here, and all ${avds.length} '
                  'AVD${avds.length == 1 ? '' : 's'} have their system image.'
            : 'adb and the emulator are here. '
                  '${unchecked.length} of ${avds.length} '
                  'AVD${avds.length == 1 ? '' : 's'} could not be read, so '
                  'whether they can boot is unknown.',
        detail: [
          ?adbVersion,
          for (final status in unchecked) '${status.name}: ${status.problem}',
        ].join('\n'),
      );
    }
    return SystemCheck(
      id: id,
      title: title,
      level: HealthLevel.warning,
      summary:
          '${broken.length} of ${avds.length} '
          'AVD${avds.length == 1 ? '' : 's'} '
          '${broken.length == 1 ? 'is' : 'are'} missing '
          '${broken.length == 1 ? 'its' : 'their'} system image and will fail '
          'to boot.',
      detail: [
        ?adbVersion,
        for (final status in broken) '${status.name}: no ${status.imagePath}',
      ].join('\n'),
      remedy:
          'The emulator lists an AVD whether or not its image was ever '
          'downloaded, and only says so on launch, as '
          '"PANIC: Cannot find AVD system path". Install the image from the '
          'SDK Manager, or with sdkmanager:',
      remedyCommand: _sdkmanagerLine(broken, sdk),
    );
  }

  Future<List<String>> _listAvds(CommandRunner runner, AndroidSdk sdk) async {
    final emulator = sdk.emulator;
    if (emulator == null) return const [];
    try {
      final result = await runner.run(
        CommandRequest(
          executable: emulator.path,
          arguments: const ['-list-avds'],
        ),
      );
      if (!result.ok) return const [];
      return parseAvdNames(result.stdout);
    } on CommandException {
      return const [];
    }
  }

  /// Resolves each AVD's `config.ini` and checks the image it names is there.
  List<AvdImageStatus> _inspectAvds(List<String> names, AndroidSdk sdk) {
    final separator = Platform.isWindows ? r'\' : '/';
    final home =
        Platform.environment['ANDROID_AVD_HOME'] ??
        _joinPath([
          Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ??
              '',
          '.android',
          'avd',
        ], separator);
    return [
      for (final name in names)
        _inspectAvd(name, home: home, separator: separator, sdk: sdk),
    ];
  }

  AvdImageStatus _inspectAvd(
    String name, {
    required String home,
    required String separator,
    required AndroidSdk sdk,
  }) {
    final ini = readTextFile(_joinPath([home, '$name.ini'], separator));
    if (ini == null) {
      return AvdImageStatus.unknown(name, 'its $name.ini could not be read');
    }
    final directory = avdDirectory(ini, avdHome: home, separator: separator);
    if (directory == null) {
      return AvdImageStatus.unknown(name, '$name.ini names no AVD folder');
    }
    final config = readTextFile(
      _joinPath([directory, 'config.ini'], separator),
    );
    if (config == null) {
      return AvdImageStatus.unknown(
        name,
        'its config.ini could not be read in $directory',
      );
    }
    final image = systemImageDirectory(
      config,
      sdkRoot: sdk.root.path,
      separator: separator,
    );
    if (image == null) {
      return AvdImageStatus.unknown(
        name,
        'its config.ini names no system image',
      );
    }
    return directoryExists(image)
        ? AvdImageStatus.installed(name, image)
        : AvdImageStatus.missingSystemImage(name, image);
  }

  /// The `sdkmanager` argument for the first missing image. `image.sysdir.1` is
  /// the package id with `/` where `;` belongs, so it is derived, not guessed.
  String? _sdkmanagerLine(List<AvdImageStatus> broken, AndroidSdk sdk) {
    final path = broken.first.imagePath;
    if (path == null) return null;
    final root = sdk.root.path;
    if (!path.startsWith(root)) return null;
    final relative = path
        .substring(root.length)
        .replaceAll(RegExp(r'^[\\/]+'), '')
        .replaceAll(RegExp(r'[\\/]+'), ';');
    if (relative.isEmpty) return null;
    return 'sdkmanager "$relative"';
  }

  // --- Disk space ----------------------------------------------------------

  /// Measures the volume the app's own data sits on — one it can name and knows
  /// it writes to, rather than "the disk".
  Future<SystemCheck> _checkDiskSpace() async {
    const id = SystemCheckId.diskSpace;
    final support = await supportDirectory();
    final root = _volumeRootOf(support.path);
    final title = 'Disk space ($root)';
    final result = await ref
        .read(hostCommandRunnerProvider)
        .run(diskSpaceRequest(onWindows: Platform.isWindows, path: root));
    final space = result.ok
        ? parseDiskSpace(result.stdout, onWindows: Platform.isWindows)
        : null;
    if (space == null) {
      return SystemCheck(
        id: id,
        title: title,
        level: HealthLevel.unknown,
        summary: 'Could not be measured, so no number is shown for it.',
        detail: result.stderr.trim().isEmpty
            ? 'The volume query exited ${result.exitCode}.'
            : result.stderr.trim(),
      );
    }
    final used = space.usedPercent;
    final level = used >= 95
        ? HealthLevel.failed
        : used >= 85
        ? HealthLevel.warning
        : HealthLevel.healthy;
    return SystemCheck(
      id: id,
      title: title,
      level: level,
      summary:
          '${formatBytes(space.freeBytes)} free of '
          '${formatBytes(space.totalBytes)} — $used% used.',
      detail: 'Karmashala keeps its database, checkpoints and logs here.',
      remedy: level == HealthLevel.healthy
          ? null
          : 'Builds, emulators and worktrees land on this volume too. Near '
                'full, a link step or an AVD boot fails with an error that '
                'names anything but the disk.',
    );
  }

  // --- helpers -------------------------------------------------------------

  Future<String?> _firstLine(
    CommandRunner runner,
    CommandRequest request,
  ) async {
    try {
      final result = await runner.run(request);
      for (final line in result.stdout.split(RegExp(r'[\r\n]+'))) {
        if (line.trim().isNotEmpty) return line.trim();
      }
    } on CommandException {
      return null;
    }
    return null;
  }

  static String _joinPath(List<String> parts, String separator) => parts
      .where((p) => p.isNotEmpty)
      .join(separator)
      .replaceAll(RegExp('${RegExp.escape(separator)}+'), separator);

  /// `C:\Users\x\AppData\...` → `C:\`; `/home/x/.local/...` → `/`.
  static String _volumeRootOf(String path) {
    if (Platform.isWindows && path.length >= 2 && path[1] == ':') {
      return '${path.substring(0, 2)}\\';
    }
    return '/';
  }
}

final systemHealthServiceProvider = Provider<SystemHealthService>(
  SystemHealthService.new,
);

/// The bridge probe, injectable so a widget test never spawns a process.
final mcpBridgeProbeProvider = Provider<McpBridgeProbe>(
  (ref) => McpBridgeProbe(runner: ref.watch(hostCommandRunnerProvider)),
);

/// The last reading, and nothing until there is one. A [Notifier] so the panel
/// and Settings read the *same* result rather than two probes of one machine.
class SystemHealthController extends Notifier<SystemHealthReport> {
  @override
  SystemHealthReport build() => SystemHealthReport.notChecked;

  /// Runs every check. Safe to call while one is in flight — the second call
  /// returns immediately rather than spawning a second set of processes.
  Future<void> refresh() async {
    if (state.running) return;
    state = state.copyWith(running: true);
    try {
      final service = ref.read(systemHealthServiceProvider);
      final environments = ref.read(environmentHealthServiceProvider);
      final results = await Future.wait([
        service.checkAll(),
        environments.checkAll(),
      ]);
      state = SystemHealthReport(
        checks: results[0] as List<SystemCheck>,
        environments: results[1] as List<EnvironmentHealth>,
        checkedAt: ref.read(clockProvider).nowUtc(),
      );
    } finally {
      if (state.running) state = state.copyWith(running: false);
    }
  }
}

final systemHealthProvider =
    NotifierProvider<SystemHealthController, SystemHealthReport>(
      SystemHealthController.new,
    );
