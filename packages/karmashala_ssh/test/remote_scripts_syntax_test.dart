import 'dart:io';
import 'dart:typed_data';

import 'package:karmashala_ssh/connection.dart';
import 'package:karmashala_ssh/host.dart';
import 'package:test/test.dart';

import 'host_deployer_test.dart' show FakeBinaries, FakeTarget;

/// Every line this package sends to a machine's shell, parsed by a real `sh`.
///
/// The fakes answer a script by a substring of it and never run it, so a
/// dropped quote or an unclosed `if` is green here and a syntax error on
/// somebody's server. `sh -n` reads a script and executes nothing.
void main() {
  final host = SshHost(
    id: 'h1',
    name: "o'brien's box",
    host: '203.0.113.9',
    port: 22,
    username: 'dlohani',
    authMethod: SshAuthMethod.privateKey,
    createdAt: DateTime.utc(2026, 9, 17),
  );

  Future<void> expectParses(Iterable<String> commands) async {
    expect(commands, isNotEmpty);
    for (final command in commands) {
      final sh = await Process.start('sh', ['-n']);
      sh.stdin.writeln(command);
      await sh.stdin.close();
      final complaint = await sh.stderr
          .transform(systemEncoding.decoder)
          .join();
      expect(
        await sh.exitCode,
        0,
        reason: '$complaint\n--- script ---\n$command',
      );
    }
  }

  test('the firewall script, for a port', () async {
    final box = _Recording('nosudo-ufw');
    await CompanionPortSetup(
      target: box,
      dial: (_, _, _) async => false,
    ).ensureOpen(47820);

    await expectParses(box.commands);
  }, testOn: '!windows');

  test('everything the installer and the deployer say, with a home that has a '
      'space and a quote in it', () async {
    final box = FakeTarget()
      ..home = "/home/o'brien the second"
      ..runningServe = null
      ..greet = ((_) => null);
    final installer = HostInstaller(
      host: host,
      deployer: HostDeployer(
        target: box,
        binaries: FakeBinaries(isBundleArchive: true),
        helloTimeout: const Duration(milliseconds: 10),
      ),
    );
    await installer.check();
    await installer.install(reinstall: true);
    await installer.start();
    await installer.stop();
    await installer.remove();

    // `attach` lines are exec channels, not scripts; the rest are.
    await expectParses(box.commands.where((c) => !c.endsWith(' attach')));
  }, testOn: '!windows');

  test('the relay\'s own, on the same home', () async {
    final box = FakeTarget()..home = "/home/o'brien the second";
    final setup = SshRelaySetup(
      host: host,
      target: box,
      remotePath:
          "/home/o'brien the second/.karmashala/bin/x.d/bin/karmashala_host",
      probe: (_, _) async => false,
    );
    await setup.check();
    await setup.start();
    await setup.stop();
    await setup.remove();

    await expectParses(box.commands);
  }, testOn: '!windows');
}

class _Recording implements HostDeployTarget {
  _Recording(this.says);

  final String says;
  final commands = <String>[];

  @override
  String get address => 'box.example';

  @override
  Future<RemoteRun> run(String command) async {
    commands.add(command);
    return RemoteRun(0, '$says\n', '');
  }

  @override
  Future<void> upload(String remotePath, Uint8List bytes) async {}

  @override
  Future<RemoteChannel> exec(String command) => throw UnimplementedError();
}
