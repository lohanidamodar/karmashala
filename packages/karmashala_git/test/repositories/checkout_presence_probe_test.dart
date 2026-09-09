import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala_git/repositories.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import '../support/temp_directory.dart';

void main() {
  late Directory tmp;
  const probe = LocalCheckoutPresenceProbe();
  final windows = windowsEnv();
  final wsl = wslEnv();
  final ssh = sshEnvFixture();

  setUp(() => tmp = Directory.systemTemp.createTempSync('karmashala_presence_'));
  tearDown(() => removeTempDirectory(tmp));

  Future<CheckoutPresence> ask(
    EnvironmentPath directory, {
    required ExecutionEnvironment environment,
  }) => probe.presenceOf(directory, environment: environment, windows: windows);

  test('a directory that is there reads as present', () async {
    final presence = await ask(
      EnvironmentPath(environmentId: 'windows', path: tmp.path),
      environment: windows,
    );
    expect(presence, CheckoutPresence.present);
  });

  test('a directory that is not there reads as absent', () async {
    final presence = await ask(
      EnvironmentPath(
        environmentId: 'windows',
        path: p.join(tmp.path, 'wt-adopt'),
      ),
      environment: windows,
    );
    expect(presence, CheckoutPresence.absent);
  });

  test('a WSL /mnt path is translated onto the host before looking', () async {
    expect(
      await ask(
        const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/mnt/c'),
        environment: wsl,
      ),
      CheckoutPresence.present,
    );
    expect(
      await ask(
        const EnvironmentPath(
          environmentId: 'wsl:Ubuntu',
          path: '/mnt/c/karmashala-no-such-folder-1f4a',
        ),
        environment: wsl,
      ),
      CheckoutPresence.absent,
    );
  }, testOn: 'windows');

  test('an SSH path is unknown, never absent', () async {
    // There is no local answer about a remote filesystem, and a host that is
    // down must never read as "the checkout was deleted".
    final presence = await ask(
      const EnvironmentPath(environmentId: 'ssh:h1', path: '/home/me/app'),
      environment: ssh,
    );
    expect(presence, CheckoutPresence.unknown);
  });

  test('a path whose environment does not match is unknown', () async {
    final presence = await ask(
      EnvironmentPath(environmentId: 'wsl:Ubuntu', path: tmp.path),
      environment: windows,
    );
    expect(presence, CheckoutPresence.unknown);
  });

  test('a path with no translation into the host is unknown', () async {
    // A distro whose name was never recorded cannot be spelled as a UNC path,
    // and a path we cannot write down is a path we cannot check.
    final nameless = ExecutionEnvironment(
      id: 'wsl:Ubuntu',
      kind: EnvironmentKind.wsl,
      name: 'Ubuntu',
      createdAt: testTime,
    );
    final presence = await ask(
      const EnvironmentPath(environmentId: 'wsl:Ubuntu', path: '/home/me/app'),
      environment: nameless,
    );
    expect(presence, CheckoutPresence.unknown);
  });
}
