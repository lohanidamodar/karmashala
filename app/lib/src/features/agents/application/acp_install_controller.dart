import 'dart:async';

import 'package:agent_cli/descriptors.dart'
    show AcpBinaryDistribution, AcpRegistryEntry;
import 'package:agent_cli/process.dart'
    show EnvironmentKind, localHostEnvironmentId;
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show AcpInstallStep, DataRefused;
import 'package:riverpod/riverpod.dart';

import '../../environments/application/environments_controller.dart';
import '../data/agents_data.dart';
import 'acp_agent_providers.dart';

/// Whether Karmashala installs into an environment of [kind]: this machine
/// and its WSL distributions, not an SSH box.
bool acpInstallReaches(EnvironmentKind kind) => kind != EnvironmentKind.ssh;

/// The registry's platform key for an environment Karmashala can install
/// into, given this machine's own ([hostPlatform], `windows-x86_64` and the
/// like): a WSL distribution is Linux on the host's CPU; an SSH box is not
/// installed into from here, so null.
String? acpRegistryPlatformForEnvironment(
  EnvironmentKind kind, {
  required String hostPlatform,
}) {
  if (!acpInstallReaches(kind)) return null;
  final cpu = hostPlatform.split('-').last;
  return switch (kind) {
    EnvironmentKind.windowsNative => 'windows-$cpu',
    EnvironmentKind.localPosix => hostPlatform,
    EnvironmentKind.wsl => 'linux-$cpu',
    EnvironmentKind.ssh => null,
  };
}

/// The binary [entry] ships for [platform] when Karmashala can install it:
/// an entry with an id, an archive and a command. Null otherwise.
AcpBinaryDistribution? acpInstallableBinary(
  AcpRegistryEntry entry,
  String platform,
) {
  final binary = entry.binaries[platform];
  if (entry.id == null || binary?.archive == null || binary?.command == null) {
    return null;
  }
  return binary;
}

/// The archive's file name, for a line saying what an install fetches.
String acpArchiveName(AcpBinaryDistribution binary) =>
    Uri.tryParse(binary.archive ?? '')?.pathSegments.lastOrNull ??
    binary.archive ??
    '';

/// One install under way or failed, keyed by [acpInstallKey].
class AcpInstallState {
  const AcpInstallState({this.steps = const {}, this.failures = const {}});

  /// What the server is doing for each install under way.
  final Map<String, AcpInstallStep> steps;

  /// The server's words for each install that failed, until the next try.
  final Map<String, String> failures;

  AcpInstallStep? stepOf(String registryId, String environmentId) =>
      steps[acpInstallKey(registryId, environmentId)];

  /// The step of an install into this machine (the Add dialog's).
  AcpInstallStep? stepHere(String registryId) =>
      stepOf(registryId, localHostEnvironmentId);

  String? failureOf(String registryId, String environmentId) =>
      failures[acpInstallKey(registryId, environmentId)];
}

String acpInstallKey(String registryId, String environmentId) =>
    '$registryId@$environmentId';

/// Installs an ACP agent the registry ships as a prebuilt archive — on one
/// machine, into the folder Karmashala keeps for it — and follows the
/// server's progress. The registry is fetched when an install is asked for,
/// never before.
class AcpInstallController extends Notifier<AcpInstallState> {
  @override
  AcpInstallState build() {
    final progress = ref.read(agentWorkProvider).installProgress.listen((p) {
      final key = acpInstallKey(p.registryId, p.environmentId);
      if (!state.steps.containsKey(key)) return;
      state = AcpInstallState(
        steps: {...state.steps, key: p.step},
        failures: state.failures,
      );
    });
    ref.onDispose(progress.cancel);
    return const AcpInstallState();
  }

  /// Installs registry entry [registryId] into [environmentId] and answers
  /// the executable's path there. With [agentId], the server also looks for
  /// that agent again so the installation is recorded. Throws, in the
  /// server's words, after recording the failure for the row to show.
  Future<String> install({
    required String registryId,
    required String environmentId,
    String? agentId,
  }) async {
    final key = acpInstallKey(registryId, environmentId);
    _set(key, step: AcpInstallStep.downloading);
    try {
      final environment = ref
          .read(environmentsControllerProvider)
          .where((e) => e.id == environmentId)
          .firstOrNull;
      if (environment == null) {
        throw DataRefused.notFound('no environment with id $environmentId');
      }
      final platform = acpRegistryPlatformForEnvironment(
        environment.kind,
        hostPlatform: ref.read(acpRegistryPlatformProvider),
      );
      if (platform == null) {
        throw DataRefused.invalid(
          'Karmashala installs agents on this machine and in WSL, not over '
          'SSH.',
        );
      }
      final catalog = await ref.read(acpRegistryCatalogProvider.future);
      final entry = catalog.byId(registryId);
      if (entry == null) {
        throw DataRefused.notFound(
          'the registry no longer lists "$registryId"',
        );
      }
      final binary = acpInstallableBinary(entry, platform);
      if (binary == null) {
        throw DataRefused.invalid(
          '${entry.label} has no build for $platform in the registry.',
        );
      }
      final installed = await ref
          .read(agentWorkProvider)
          .installAcpBinary(
            environmentId: environmentId,
            registryId: registryId,
            version: entry.version ?? 'latest',
            archive: binary.archive!,
            command: binary.command!,
            args: binary.args,
            sha256: binary.sha256,
            agentId: agentId,
          );
      _set(key);
      return installed.executablePath;
    } on Object catch (error) {
      _set(key, failure: error is DataRefused ? error.message : '$error');
      rethrow;
    }
  }

  /// Installs into this machine, for a row being added from the registry.
  Future<String> installHere(String registryId) =>
      install(registryId: registryId, environmentId: localHostEnvironmentId);

  void _set(String key, {AcpInstallStep? step, String? failure}) {
    final steps = {...state.steps}..remove(key);
    final failures = {...state.failures}..remove(key);
    if (step != null) steps[key] = step;
    if (failure != null) failures[key] = failure;
    state = AcpInstallState(steps: steps, failures: failures);
  }
}

final acpInstallControllerProvider =
    NotifierProvider<AcpInstallController, AcpInstallState>(
      AcpInstallController.new,
    );

/// The words for a step, for a row or dialog following an install.
String describeAcpInstallStep(AcpInstallStep step) => switch (step) {
  AcpInstallStep.downloading => 'Downloading…',
  AcpInstallStep.unpacking => 'Unpacking…',
  AcpInstallStep.detecting => 'Detecting…',
};
