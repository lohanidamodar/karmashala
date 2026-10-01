import 'dart:convert';
import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/data/data_service.dart';
import 'package:karmashala_host/src/env/server_env_vault.dart';
import 'package:karmashala_store/database.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The server's environment vault (slice 5a), driven as a client drives it —
/// `env.*` through a [DataSession], answered when done — over a data folder
/// in a temp directory. Write-only: no answer or change carries a value.
void main() {
  late Directory tmp;
  late AppDatabase database;
  late DataService data;
  late ServerEnvVault vault;
  late DataSession client;
  late DataSession other;
  late List<DataChange> toClient;
  late List<DataChange> toOther;
  final t0 = DateTime.utc(2026, 9, 27, 8);

  ServerEnvVault open() {
    final opened = ServerEnvVault(
      dataDirectory: tmp.path,
      tell: data.announce,
      clock: () => t0,
    );
    data
      ..envVault = opened
      ..greeters.add(opened.greeting);
    return opened;
  }

  Future<R> ask<R>(DataRequest<R> request) async =>
      (await client.handleLater(request)).value;

  Future<DataRefused> refusal(DataRequest<Object?> request) async {
    try {
      await client.handleLater(request);
    } on DataRefused catch (refused) {
      return refused;
    }
    fail('${request.kind} was not refused');
  }

  File vaultFile() => File(p.join(tmp.path, 'secrets', 'env.json'));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('ks-env-vault-');
    database = AppDatabase.memory();
    data = DataService(database);
    vault = open();
    toClient = [];
    toOther = [];
    client = data.open((batch) => toClient.addAll(batch.changes));
    other = data.open((batch) => toOther.addAll(batch.changes));
    client.handle(const DataSubscribe());
    other.handle(const DataSubscribe());
  });

  tearDown(() {
    database.close();
    tmp.deleteSync(recursive: true);
  });

  test('a subscriber is greeted with the names, empty at first', () {
    final greeted = toClient.whereType<EnvVariablesChanged>().single;
    expect(greeted.variables, isEmpty);
  });

  test('set, list and remove: names come back, values never do', () async {
    await ask(const EnvSet('API_TOKEN', 's3cret-value'));
    await ask(const EnvSet('OTHER', 'plain'));
    final names = await ask(const EnvList());
    expect([for (final n in names) n.name], ['API_TOKEN', 'OTHER']);
    expect(names.first.updatedAt, t0);

    // Every client hears the names, and no batch carries a value.
    final told = toOther.whereType<EnvVariablesChanged>().last;
    expect([for (final n in told.variables) n.name], ['API_TOKEN', 'OTHER']);
    final wire = jsonEncode([
      for (final change in [...toClient, ...toOther]) change.toJson(),
    ]);
    expect(wire, isNot(contains('s3cret-value')));
    final answer = DataEnvelope.answer(
      1,
      const EnvList(),
      await client.handleLater(const EnvList()),
    );
    expect(jsonEncode(answer), isNot(contains('s3cret-value')));

    // Only the server's own launches read a value.
    expect(vault.overlay(), {'API_TOKEN': 's3cret-value', 'OTHER': 'plain'});

    await ask(const EnvRemove('OTHER'));
    expect([for (final n in await ask(const EnvList())) n.name], ['API_TOKEN']);
    expect(vault.overlay(), {'API_TOKEN': 's3cret-value'});
    // Removing what is not there is not a refusal.
    await ask(const EnvRemove('NEVER_SET'));
  });

  test('a rename moves the value in one write; never both names', () async {
    await ask(const EnvSet('API_TOKEN', 's3cret-value'));
    await ask(const EnvSet('OTHER', 'plain'));

    await ask(const EnvRename('API_TOKEN', 'GH_TOKEN'));
    expect(vault.overlay(), {'GH_TOKEN': 's3cret-value', 'OTHER': 'plain'});
    final reopened = ServerEnvVault(dataDirectory: tmp.path, tell: (_) {});
    expect(reopened.overlay(), vault.overlay());

    await ask(const EnvRename('GH_TOKEN', 'GITHUB_TOKEN', value: 'new'));
    expect(vault.overlay(), {'GITHUB_TOKEN': 'new', 'OTHER': 'plain'});
    final told = toOther.whereType<EnvVariablesChanged>().last;
    expect([for (final n in told.variables) n.name], ['GITHUB_TOKEN', 'OTHER']);

    // Onto another variable, from one that is gone, or to a refused name:
    // refused, and nothing moves.
    expect(
      (await refusal(const EnvRename('GITHUB_TOKEN', 'OTHER'))).code,
      DataRefusalCode.invalid,
    );
    expect(
      (await refusal(const EnvRename('NEVER_SET', 'X'))).code,
      DataRefusalCode.notFound,
    );
    expect(
      (await refusal(const EnvRename('GITHUB_TOKEN', 'PATH'))).code,
      DataRefusalCode.invalid,
    );
    expect(vault.overlay(), {'GITHUB_TOKEN': 'new', 'OTHER': 'plain'});
  });

  test('a value outlives the server, read back from its own file', () async {
    await ask(const EnvSet('API_TOKEN', 'kept'));
    expect(vaultFile().existsSync(), isTrue);
    final reopened = ServerEnvVault(dataDirectory: tmp.path, tell: (_) {});
    expect(reopened.overlay(), {'API_TOKEN': 'kept'});
    expect([for (final n in reopened.names) n.name], ['API_TOKEN']);
  });

  test('the folder and file are owner-only', () async {
    await ask(const EnvSet('API_TOKEN', 'kept'));
    final dir = Directory(p.join(tmp.path, 'secrets'));
    expect(dir.statSync().mode & 0x1ff, 0x1c0); // 0700
    expect(vaultFile().statSync().mode & 0x1ff, 0x180); // 0600
    expect(File('${vaultFile().path}.tmp').existsSync(), isFalse);
  }, skip: Platform.isWindows ? 'POSIX modes; Windows uses an ACL' : false);

  test(
    'names and values the rules refuse are refused, nothing written',
    () async {
      expect(
        (await refusal(const EnvSet('', 'x'))).code,
        DataRefusalCode.invalid,
      );
      expect(
        (await refusal(const EnvSet('KARMASHALA_SESSION_ID', 'x'))).code,
        DataRefusalCode.invalid,
      );
      expect(
        (await refusal(const EnvSet('PATH', 'x'))).code,
        DataRefusalCode.invalid,
      );
      expect(
        (await refusal(const EnvSet('OK', 'a\u0000b'))).code,
        DataRefusalCode.invalid,
      );
      expect(await ask(const EnvList()), isEmpty);
      expect(vaultFile().existsSync(), isFalse);
    },
  );

  test('an unreadable vault is left alone and refuses writes', () async {
    vaultFile().parent.createSync(recursive: true);
    vaultFile().writeAsStringSync('not json');
    open();
    expect(await ask(const EnvList()), isEmpty);
    expect(
      (await refusal(const EnvSet('OK', 'x'))).code,
      DataRefusalCode.failed,
    );
    expect(vaultFile().readAsStringSync(), 'not json');
  });

  test('a server without a vault refuses the work as unavailable', () async {
    data.envVault = null;
    expect((await refusal(const EnvList())).code, DataRefusalCode.unavailable);
  });
}
