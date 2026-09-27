import 'package:agent_cli/process.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:test/test.dart';

/// A private key is read on the machine that dials — the server for its own
/// connections, the app for its terminal panes — from whichever local
/// environment owns its path. Moved from the app (slice 3a).
void main() {
  final t0 = DateTime.utc(2026, 9, 27);
  final windows = ExecutionEnvironment(
    id: 'windows',
    kind: EnvironmentKind.windowsNative,
    name: 'Windows',
    createdAt: t0,
  );
  final ubuntu = ExecutionEnvironment(
    id: 'wsl:Ubuntu',
    kind: EnvironmentKind.wsl,
    name: 'Ubuntu',
    wslDistribution: 'Ubuntu',
    createdAt: t0,
  );
  final box = ExecutionEnvironment(
    id: 'ssh:h1',
    kind: EnvironmentKind.ssh,
    name: 'box',
    sshHostId: 'h1',
    createdAt: t0,
  );
  late List<EnvironmentPath> read;

  setUp(() => read = []);

  EnvironmentPrivateKeyReader reader() => EnvironmentPrivateKeyReader(
    environmentOf: (id) =>
        [windows, ubuntu, box].where((e) => e.id == id).firstOrNull,
    readLocal: (path) async {
      read.add(path);
      return 'PEM';
    },
  );

  test('a Windows key path is read as written', () async {
    const path = EnvironmentPath(
      environmentId: 'windows',
      path: r'C:\Users\me\.ssh\id_ed25519',
    );
    expect(await reader().read(path), 'PEM');
    expect(read.single, path);
  });

  test('a WSL key is read through its UNC form', () async {
    // The reading process opens files with the Windows API: `/home/me/.ssh/id`
    // in a distribution is not a path it can open, but the same file has a
    // name it can.
    await reader().read(
      const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/home/me/.ssh/id_ed25519',
      ),
    );
    expect(read.single.environmentId, 'windows');
    expect(read.single.path, r'\\wsl.localhost\Ubuntu\home\me\.ssh\id_ed25519');
  });

  test('a WSL /mnt path resolves to the drive it actually is', () async {
    await reader().read(
      const EnvironmentPath(
        environmentId: 'wsl:Ubuntu',
        path: '/mnt/c/keys/id_ed25519',
      ),
    );
    expect(read.single.path, r'C:\keys\id_ed25519');
  });

  test('an unknown environment is read as written, not guessed at', () async {
    const path = EnvironmentPath(environmentId: 'wsl:Gone', path: '/home/x');
    await reader().read(path);
    expect(read.single, path);
  });

  test('a key recorded on the remote host itself is refused', () {
    // Fetching a key over the connection it is meant to authenticate is not
    // a thing that can work.
    expect(
      () => EnvironmentPrivateKeyReader(
        environmentOf: (_) => box,
      ).read(const EnvironmentPath(environmentId: 'ssh:h1', path: '/k')),
      throwsA(isA<SshConnectionException>()),
    );
  });

  test('only local environments are offered as a key home', () {
    final offered = keyHostingEnvironments([windows, ubuntu, box]);
    expect(offered.map((e) => e.id), ['windows', 'wsl:Ubuntu']);
  });
}
