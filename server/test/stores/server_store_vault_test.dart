import 'dart:io';

import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';
import 'package:karmashala_host/src/stores/server_store_vault.dart';
import 'package:path/path.dart' as p;
import 'package:store_console/store_console.dart' show StoreKind;
import 'package:store_console_apple/store_console_apple.dart';
import 'package:store_console_play/store_console_play.dart';
import 'package:test/test.dart';

/// The server's app-store credentials file, over a data folder in a temp
/// directory. Test values only; never a real key.
void main() {
  late Directory tmp;
  final t0 = DateTime.utc(2026, 10, 1, 8);

  const pem =
      '-----BEGIN PRIVATE KEY-----\nnot-a-real-key\n-----END PRIVATE KEY-----';
  const apple = AppleApiKey(
    keyId: 'KEY123',
    issuerId: 'issuer-1',
    privateKeyPem: pem,
    vendorNumber: '8800',
  );
  const play = PlayAccount(
    serviceAccountJson:
        '{"type":"service_account","private_key":"not-a-real-key",'
        '"client_email":"bot@example.iam.gserviceaccount.com"}',
    reportsBucket: 'pubsite_prod_1',
    packageNames: ['com.example.one'],
  );

  File vaultFile() => File(p.join(tmp.path, 'secrets', 'stores.json'));

  setUp(() => tmp = Directory.systemTemp.createTempSync('ks-store-vault-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('empty at first, and nothing written until something is set', () {
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    expect(vault.apple, isNull);
    expect(vault.play, isNull);
    expect(vaultFile().existsSync(), isFalse);
  });

  test('both credentials outlive the server, read back whole', () async {
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    await vault.setApple(HeldAppleKey(apple, _t0));
    await vault.setPlay(HeldPlayAccount(play, t0));

    final reopened = ServerStoreVault(dataDirectory: tmp.path);
    expect(reopened.apple!.key.keyId, 'KEY123');
    expect(reopened.apple!.key.privateKeyPem, pem);
    expect(reopened.apple!.key.vendorNumber, '8800');
    expect(reopened.apple!.importedAt, _t0);
    expect(reopened.play!.account.serviceAccountJson, play.serviceAccountJson);
    expect(reopened.play!.account.reportsBucket, 'pubsite_prod_1');
    expect(reopened.play!.account.packageNames, ['com.example.one']);
    expect(reopened.play!.importedAt, t0);
    expect(File('${vaultFile().path}.tmp').existsSync(), isFalse);
  });

  test('remove forgets one store and keeps the other', () async {
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    await vault.setApple(HeldAppleKey(apple, _t0));
    await vault.setPlay(HeldPlayAccount(play, t0));
    await vault.remove(StoreKind.appStore);

    final reopened = ServerStoreVault(dataDirectory: tmp.path);
    expect(reopened.apple, isNull);
    expect(reopened.play, isNotNull);
  });

  test('no toString shows a key', () {
    final held = HeldAppleKey(apple, _t0);
    expect('$held', isNot(contains('not-a-real-key')));
    expect('${HeldPlayAccount(play, t0)}', isNot(contains('not-a-real-key')));
  });

  test('the folder and file are owner-only', () async {
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    await vault.setApple(HeldAppleKey(apple, _t0));
    final dir = Directory(p.join(tmp.path, 'secrets'));
    expect(dir.statSync().mode & 0x1ff, 0x1c0); // 0700
    expect(vaultFile().statSync().mode & 0x1ff, 0x180); // 0600
  }, skip: Platform.isWindows ? 'POSIX modes; Windows uses an ACL' : false);

  test('an unreadable file is left alone and refuses writes', () async {
    vaultFile().parent.createSync(recursive: true);
    vaultFile().writeAsStringSync('not json');
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    expect(vault.apple, isNull);
    await expectLater(
      vault.setApple(HeldAppleKey(apple, _t0)),
      throwsA(
        isA<DataRefused>().having(
          (refused) => refused.code,
          'code',
          DataRefusalCode.failed,
        ),
      ),
    );
    expect(vault.apple, isNull);
    expect(vaultFile().readAsStringSync(), 'not json');
  });

  test('a file of another version is not read and not overwritten', () async {
    vaultFile().parent.createSync(recursive: true);
    vaultFile().writeAsStringSync('{"version":2}');
    final vault = ServerStoreVault(dataDirectory: tmp.path);
    await expectLater(
      vault.remove(StoreKind.googlePlay),
      throwsA(isA<DataRefused>()),
    );
    expect(vaultFile().readAsStringSync(), '{"version":2}');
  });
}

final _t0 = DateTime.utc(2026, 9, 30, 12);
