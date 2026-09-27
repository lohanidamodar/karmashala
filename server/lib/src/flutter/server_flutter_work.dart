import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_automations/store.dart' show CheckoutRows;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';
import 'package:karmashala_store/database.dart';
import 'package:karmashala_verification/artifacts.dart';
import 'package:karmashala_verification/command_checks.dart';
import 'package:karmashala_verification/store.dart';
import 'package:path/path.dart' as p;

import '../data/runs_work.dart';
import '../domain/session_registry.dart';
import '../devices/server_device_claims.dart' show FlutterDeviceClaims;
import '../domain/uuid.dart';
import '../ssh/ssh_domain.dart' show RemoteSessions;
import 'attached_apps.dart';
import 'flutter_logs_source.dart';
import 'flutter_loop.dart';
import 'flutter_sdk_readings.dart';
import 'hosted_runs.dart';
import 'project_builds.dart';

/// Where the server's runs write their `--vmservice-out-file`, under its data
/// directory.
const String kVmServiceDirectoryName = 'vmservice';

/// The server's Flutter work (slice 3d), whole: its hosted runs, the SDK in
/// each environment, the apps it is attached to, the Flutter loop and the
/// project builds — and the answers to what a client asks of them.
class ServerFlutterWork implements FlutterWork {
  ServerFlutterWork({
    required SessionRegistry registry,
    required AppDatabase database,
    required void Function(List<DataChange> changes) tell,
    required String dataDirectory,
    required Map<String, String> hostEnvironment,
    CommandRunnerFactory runners = const CommandRunnerFactory(),
    DtdChannelOpener openDtd = openDtdOverWebSocket,
    VmServiceConnector connect = connectVmServiceOverWebSocket,
    DtdPidFiles? dtdPidFiles,
    required FlutterDeviceClaims claims,
    Future<String?> Function()? androidSdkRoot,
    String? operatingSystem,
    bool? windows,
    DateTime Function()? clock,
    String Function()? newId,
    void Function(String message)? log,
    RemoteSessions? remote,
  }) {
    final now = clock ?? () => DateTime.now().toUtc();
    final ids = newId ?? newUuid;
    final os = operatingSystem ?? Platform.operatingSystem;
    final rows = CheckoutRows(database);
    hosted = HostedRuns(
      registry: registry,
      tell: tell,
      newId: ids,
      clock: now,
      windows: windows,
      remote: remote,
    );
    sdk = ServerFlutterSdk(database: database, runners: runners, clock: now);
    apps = ServerAttachedApps(
      directory: VmServiceUriDirectory(
        Directory(p.join(dataDirectory, kVmServiceDirectoryName)),
      ),
      dtdPidFiles:
          dtdPidFiles ??
          DtdPidFiles.forEnvironment(hostEnvironment, operatingSystem: os),
      openDtd: openDtd,
      connect: connect,
      clock: now,
      onChanged: (registry) => tell([FlutterAppsChanged(registry)]),
      log: log,
    );
    loop = ServerFlutterLoop(
      hosted: hosted,
      sdk: sdk,
      apps: apps,
      rows: rows,
      recorder: CommandCheckRecorder(
        StoreVerificationRecords(
          VerificationDao(database),
          onRecorded: (run) => tell([VerificationRunChanged(run)]),
        ),
        VerificationArtifactStore(
          Directory(p.join(dataDirectory, 'verification')),
        ),
        newId: () => verificationRunId(now()),
        now: now,
      ),
      runners: runners,
      hostEnvironment: hostEnvironment,
      claims: claims,
      androidSdkRoot: androidSdkRoot,
      operatingSystem: os,
      newId: ids,
      clock: now,
    );
    builds = ServerProjectBuilds(
      hosted: hosted,
      sdk: sdk,
      rows: rows,
      runners: runners,
    );
    logs = FlutterLogsSource(apps);
    _rows = rows;
  }

  late final HostedRuns hosted;
  late final ServerFlutterSdk sdk;
  late final ServerAttachedApps apps;
  late final ServerFlutterLoop loop;
  late final ServerProjectBuilds builds;

  /// Registered under `kFlutterLogsStream`.
  late final FlutterLogsSource logs;
  late final CheckoutRows _rows;

  @override
  Future<Object?> handle(FlutterWorkRequest<Object?> request) async {
    try {
      return await _handle(request);
    } on FlutterAppException catch (error) {
      throw DataRefused(
        error.failure == FlutterAppFailure.unknownApp
            ? DataRefusalCode.notFound
            : DataRefusalCode.failed,
        error.message,
      );
    }
  }

  Future<Object?> _handle(FlutterWorkRequest<Object?> request) async {
    switch (request) {
      case FlutterApps(:final look):
        if (look) await apps.look();
        return apps.registry;
      case FlutterAttach(
        :final vmServiceUri,
        :final deviceSerial,
        :final label,
      ):
        return apps.attach(
          vmServiceUri,
          deviceSerial: deviceSerial,
          label: label,
        );
      case FlutterReload(:final appId, :final full):
        if (full) {
          await apps.hotRestart(appId);
        } else {
          await apps.hotReload(appId);
        }
        return const DataAck();
      case FlutterDetach(:final appId):
        await apps.detach(appId);
        return const DataAck();
      case FlutterForget(:final appId):
        await apps.forget(appId);
        return const DataAck();
      case FlutterPickWidget(:final appId, :final timeoutSeconds):
        final selection = await apps.pickWidget(
          appId,
          timeout: Duration(seconds: timeoutSeconds.clamp(1, 600)),
        );
        return selection.toPromptText();
      case FlutterSdk(:final environmentId, :final force):
        final environment =
            _rows.environment(environmentId) ??
            (throw DataRefused.notFound(
              'no environment "$environmentId" is recorded',
            ));
        return sdk.readFor(environment, force: force);
    }
  }

  @override
  List<DataChange> greeting() => [
    // Only what is under way: a server that has not looked says nothing.
    if (apps.registry.hasLooked || apps.registry.apps.isNotEmpty)
      FlutterAppsChanged(apps.registry),
    for (final run in hosted.runs)
      if (run.isLive) HostedRunChanged(run),
  ];

  /// Lets go of every link, daemon and watcher; every run keeps going.
  Future<void> close() async {
    await loop.close();
    await apps.close();
  }
}
