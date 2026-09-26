import 'package:karmashala_store/database.dart';
import 'package:karmashala/src/features/environments/data/execution_environment_dao.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/ssh/data/environment_key_reader.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

void main() {
  late AppDatabase db;
  late ExecutionEnvironmentDao environments;
  late List<EnvironmentPath> read;

  setUp(() {
    db = AppDatabase.memory();
    environments = ExecutionEnvironmentDao(db);
    environments.upsert(windowsEnv());
    environments.upsert(wslEnv(id: 'wsl:Ubuntu', distro: 'Ubuntu'));
    read = [];
  });
  tearDown(() => db.close());

  EnvironmentPrivateKeyReader reader() => EnvironmentPrivateKeyReader(
    environments: environments,
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
    // The desktop process reads with the Windows API: `/home/me/.ssh/id` in a
    // distribution is not a path it can open, but the same file has a name it
    // can. Without this the pairing would be recorded correctly and then used
    // to look on the wrong machine.
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

  test('a key recorded on the remote host itself is refused', () async {
    // Fetching a key over the connection it is meant to authenticate is not a
    // thing that can work, and reinterpreting the path as a local one is the
    // bug principle 2 exists to prevent.
    expect(
      () => EnvironmentPrivateKeyReader(environments: environments).read(
        const EnvironmentPath(
          environmentId: 'ssh:h1',
          path: '/home/dev/.ssh/id_ed25519',
        ),
      ),
      throwsA(isA<SshConnectionException>()),
    );
  });

  test('only local environments are offered as a key home', () {
    final offered = keyHostingEnvironments([
      windowsEnv(),
      wslEnv(),
      sshEnvFixture(),
    ]);
    expect(offered.map((e) => e.id), ['windows', 'wsl:Ubuntu']);
  });
}
