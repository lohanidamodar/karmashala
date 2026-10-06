import 'dart:io';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/temp_directory.dart';

/// Whether an installed store still holds the endpoint file the app wrote: the
/// question the running app asks to notice one deleted under it.
void main() {
  const installer = AgentHookInstaller();
  const endpoint = AgentHookEndpoint(port: 47821, token: 'tokenOne');
  final environment = Platform.isWindows
      ? EnvironmentKind.windowsNative
      : EnvironmentKind.localPosix;

  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('karmashala_epcur_'));
  tearDown(() => removeTempDirectory(home));

  for (final descriptor in [
    for (final d in AgentRegistry.builtIn.descriptors)
      if (d.hooks != null) d,
  ]) {
    group(descriptor.id, () {
      late String storeHome;
      File endpointFile() =>
          File(p.join(storeHome, '$agentHookMarker.endpoint'));

      Future<bool> current([AgentHookEndpoint e = endpoint]) =>
          installer.endpointIsCurrent(
            descriptor: descriptor,
            storeHome: storeHome,
            endpoint: e,
            environment: environment,
          );

      setUp(() async {
        storeHome = p.joinAll([
          home.path,
          ...p.posix.split(descriptor.store!.homeDirectoryName),
        ]);
        Directory(storeHome).createSync(recursive: true);
        expect(
          await installer.install(
            descriptor: descriptor,
            storeHome: storeHome,
            endpoint: endpoint,
            environment: environment,
          ),
          isTrue,
        );
      });

      test('is current right after an install', () async {
        expect(await current(), isTrue);
      });

      test('is not once the file is deleted', () async {
        endpointFile().deleteSync();
        expect(await current(), isFalse);
      });

      test('is not once the file names another endpoint', () async {
        expect(
          await current(const AgentHookEndpoint(port: 1, token: 'tokenTwo')),
          isFalse,
        );
      });

      test('is not once the file was edited', () async {
        endpointFile().writeAsStringSync('url=\ntoken=\n');
        expect(await current(), isFalse);
      });
    });
  }
}
