import 'package:karmashala_store/database.dart';
import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/ssh/data/ssh_host_dao.dart';
import 'package:karmashala_ssh/connection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fixtures.dart';

SshHost host({
  String id = 'h1',
  String name = 'build-box',
  SshAuthMethod auth = SshAuthMethod.privateKey,
  EnvironmentPath? key,
  String? defaultDirectory,
}) => SshHost(
  id: id,
  name: name,
  host: 'build.example.com',
  port: 2222,
  username: 'dev',
  authMethod: auth,
  privateKey:
      key ??
      (auth == SshAuthMethod.privateKey
          ? const EnvironmentPath(
              environmentId: 'windows',
              path: r'C:\Users\me\.ssh\id_ed25519',
            )
          : null),
  defaultDirectory: defaultDirectory == null
      ? null
      : EnvironmentPath(
          environmentId: sshEnvironmentId(id),
          path: defaultDirectory,
        ),
  createdAt: testTime,
);

void main() {
  late AppDatabase db;
  late SshHostDao dao;

  setUp(() {
    db = AppDatabase.memory();
    dao = SshHostDao(db);
  });
  tearDown(() => db.close());

  test('round-trips a key-authenticated host', () {
    final saved = host(defaultDirectory: '/home/dev/src');
    dao.upsert(saved);
    expect(dao.getById('h1'), saved);
  });

  test('the private key path keeps the environment that owns it', () {
    dao.upsert(host());
    final loaded = dao.getById('h1')!;
    expect(loaded.privateKey!.environmentId, 'windows');
    expect(loaded.privateKey!.path, r'C:\Users\me\.ssh\id_ed25519');
  });

  test('the default directory belongs to the remote environment', () {
    dao.upsert(host(defaultDirectory: '/home/dev/src'));
    final loaded = dao.getById('h1')!;
    expect(loaded.defaultDirectory!.environmentId, 'ssh:h1');
    expect(loaded.environmentId, 'ssh:h1');
  });

  test('a password host stores no key and no secret', () {
    dao.upsert(host(auth: SshAuthMethod.password));
    final loaded = dao.getById('h1')!;
    expect(loaded.authMethod, SshAuthMethod.password);
    expect(loaded.privateKey, isNull);
  });

  test('the table has no column that could hold a credential', () {
    final columns = db
        .query('PRAGMA table_info(ssh_hosts);')
        .map((r) => (r['name']! as String).toLowerCase())
        .toList();
    for (final forbidden in [
      'password',
      'passphrase',
      'secret',
      'private_key',
    ]) {
      expect(
        columns,
        isNot(contains(forbidden)),
        reason: 'ssh_hosts must never store credentials',
      );
    }
    expect(columns, contains('private_key_path'));
  });

  test('upsert updates in place and delete removes', () {
    dao.upsert(host());
    dao.upsert(host(name: 'renamed'));
    expect(dao.getAll(), hasLength(1));
    expect(dao.getById('h1')!.name, 'renamed');
    dao.delete('h1');
    expect(dao.getAll(), isEmpty);
  });

  test('toString leaks the address but never the key path', () {
    final text = host().toString();
    expect(text, contains('dev@build.example.com:2222'));
    expect(text, isNot(contains('id_ed25519')));
  });
}
