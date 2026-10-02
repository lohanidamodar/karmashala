import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:riverpod/riverpod.dart';

import '../data/acp_agents_data.dart';
import 'agent_installations_controller.dart';

export '../data/acp_agents_data.dart' show acpAgentRowsProvider;

/// The registry's platform key for this machine: `windows-x86_64`,
/// `darwin-aarch64`, `linux-x86_64`, … Read off `Platform.version`, whose
/// tail names the build (`on "windows_x64"`), so no `dart:ffi` is needed.
String acpRegistryPlatformFor({
  required String operatingSystem,
  required String version,
}) {
  final os = operatingSystem == 'macos' ? 'darwin' : operatingSystem;
  final arch = RegExp(r'"\w+?_(\w+)"').firstMatch(version)?.group(1);
  final cpu = switch (arch) {
    'arm64' => 'aarch64',
    'arm' => 'arm',
    _ => 'x86_64',
  };
  return '$os-$cpu';
}

final acpRegistryPlatformProvider = Provider<String>(
  (ref) => acpRegistryPlatformFor(
    operatingSystem: Platform.operatingSystem,
    version: Platform.version,
  ),
);

/// Makes the client one registry fetch uses; a test hands in a fake.
final acpRegistryHttpClientProvider = Provider<HttpClient Function()>(
  (ref) => HttpClient.new,
);

/// Why the registry could not be read, short enough to follow a colon.
class AcpRegistryUnavailable implements Exception {
  const AcpRegistryUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The public ACP registry, fetched once per listener and dropped with the
/// last one — a dialog's life, no longer. Throws [AcpRegistryUnavailable].
final acpRegistryCatalogProvider = FutureProvider.autoDispose(
  // No silent retry: the dialog says why, and reopening it asks again.
  retry: (_, _) => null,
  (ref) async {
    final client = ref.read(acpRegistryHttpClientProvider)();
    try {
      return await AcpRegistryCatalog.fetch((url) async {
        final request = await client.getUrl(url);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close();
        final body = await response.transform(utf8.decoder).join();
        if (response.statusCode != HttpStatus.ok) {
          throw AcpRegistryUnavailable(
            'the registry answered HTTP ${response.statusCode}',
          );
        }
        return body;
      }).timeout(const Duration(seconds: 15));
    } on AcpRegistryUnavailable {
      rethrow;
    } on TimeoutException {
      throw const AcpRegistryUnavailable('the registry did not answer');
    } on SocketException catch (e) {
      throw AcpRegistryUnavailable('no connection (${e.message})');
    } on HandshakeException {
      throw const AcpRegistryUnavailable('secure connection failed');
    } on FormatException {
      throw const AcpRegistryUnavailable(
        'the registry sent something unreadable',
      );
    } catch (e) {
      throw AcpRegistryUnavailable('$e');
    } finally {
      client.close(force: true);
    }
  },
);

/// What the ACP agents section is doing beyond showing its rows.
class AcpAgentsSetupState {
  const AcpAgentsSetupState({this.discovering = false, this.discoveryError});

  /// Agent detection is running for an agent just added.
  final bool discovering;
  final String? discoveryError;
}

/// Adds, edits and removes the ACP agents a person keeps, and after a new one
/// asks the server to look for it once so it becomes an installation.
class AcpAgentsSetup extends Notifier<AcpAgentsSetupState> {
  @override
  AcpAgentsSetupState build() => const AcpAgentsSetupState();

  Future<AcpAgentRow> save({
    String? id,
    required String name,
    required String command,
    List<String> args = const [],
    Map<String, String> env = const {},
    AcpAgentSource source = AcpAgentSource.custom,
    String? registryId,
  }) async {
    final row = await ref
        .read(acpAgentsDataProvider)
        .put(
          id: id,
          name: name,
          command: command,
          args: args,
          env: env,
          source: source,
          registryId: registryId,
        );
    if (id == null) unawaited(_discover());
    return row;
  }

  Future<void> remove(String id) => ref.read(acpAgentsDataProvider).delete(id);

  Future<void> _discover() async {
    state = const AcpAgentsSetupState(discovering: true);
    try {
      await ref
          .read(agentInstallationsControllerProvider.notifier)
          .discoverAll();
      state = const AcpAgentsSetupState();
    } on Object catch (e) {
      state = AcpAgentsSetupState(discoveryError: 'Discovery failed: $e');
    }
  }
}

final acpAgentsSetupProvider =
    NotifierProvider<AcpAgentsSetup, AcpAgentsSetupState>(AcpAgentsSetup.new);
