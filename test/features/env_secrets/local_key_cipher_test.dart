import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:karmashala/src/features/env_secrets/data/env_vault.dart';
import 'package:karmashala/src/features/env_secrets/data/local_key_cipher.dart';
import 'package:karmashala/src/features/env_secrets/domain/env_variable.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:path/path.dart' as p;

class _FakePermissions extends HandshakePermissions {
  _FakePermissions({this.fileOk = true});

  final bool fileOk;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => fileOk;

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      true;
}

EnvVariable _variable({
  String id = 'v1',
  String name = 'TOKEN',
  String value = 'super-secret-value',
}) => EnvVariable(
  id: id,
  name: name,
  value: value,
  secret: true,
  updatedAt: DateTime.utc(2026),
);

void main() {
  late Directory temp;
  late Directory keyDir;
  late Directory vaultRoot;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('karmashala_env_key_test');
    keyDir = Directory(p.join(temp.path, 'local'));
    vaultRoot = Directory(p.join(temp.path, 'support'));
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Future<LocalKeyEnvValueCipher> cipher({bool fileOk = true}) =>
      LocalKeyEnvValueCipher.open(
        directory: keyDir,
        permissions: _FakePermissions(fileOk: fileOk),
      );

  Future<EnvVault> vaultWith(LocalKeyEnvValueCipher c) async {
    final vault = EnvVault(
      directory: Directory(p.join(vaultRoot.path, EnvVault.directoryName)),
      cipher: c,
      permissions: _FakePermissions(),
    );
    await vault.load();
    return vault;
  }

  group('the key', () {
    test('is created on first use and reused after', () async {
      final first = await cipher();
      final file = File(
        p.join(keyDir.path, LocalKeyEnvValueCipher.keyFileName),
      );
      expect(file.existsSync(), isTrue);
      expect(base64.decode(file.readAsStringSync()).length, kEnvKeyBytes);

      final sealed = await first.wrap('hello');
      final second = await cipher();
      expect(await second.unwrap(sealed), 'hello');
    });

    test('is not written when it cannot be restricted to this account',
        () async {
      await expectLater(
        cipher(fileOk: false),
        throwsA(isA<EnvKeyUnavailable>()),
      );
      expect(
        File(
          p.join(keyDir.path, LocalKeyEnvValueCipher.keyFileName),
        ).existsSync(),
        isFalse,
        reason: 'a half-made key must not be left for the next run to adopt',
      );
    });

    test('a truncated key file is refused rather than used', () async {
      await cipher();
      await File(
        p.join(keyDir.path, LocalKeyEnvValueCipher.keyFileName),
      ).writeAsString(base64.encode([1, 2, 3]));

      await expectLater(cipher(), throwsA(isA<EnvKeyUnavailable>()));
    });
  });

  group('sealing', () {
    test('a value round-trips', () async {
      final c = await cipher();
      expect(await c.unwrap(await c.wrap('super-secret-value')),
          'super-secret-value');
    });

    test('the ciphertext does not contain the plaintext', () async {
      final c = await cipher();
      final sealed = await c.wrap('super-secret-value');
      expect(sealed, isNot(contains('super-secret-value')));
      expect(
        utf8.decode(base64.decode(sealed), allowMalformed: true),
        isNot(contains('super-secret-value')),
      );
    });

    test('the same value seals differently each time (a fresh nonce)',
        () async {
      final c = await cipher();
      expect(await c.wrap('same'), isNot(await c.wrap('same')));
    });

    test('a tampered ciphertext does not decrypt', () async {
      final c = await cipher();
      final sealed = base64.decode(await c.wrap('super-secret-value'));
      sealed[sealed.length - 1] ^= 0xFF;
      expect(await c.unwrap(base64.encode(sealed)), isNull);
    });

    test('another key cannot open it', () async {
      final sealed = await (await cipher()).wrap('super-secret-value');
      await File(
        p.join(keyDir.path, LocalKeyEnvValueCipher.keyFileName),
      ).delete();

      expect(await (await cipher()).unwrap(sealed), isNull);
    });
  });

  group('the vault, encrypted', () {
    test('reports localKey protection and round-trips', () async {
      final vault = await vaultWith(await cipher());
      await vault.save(EnvVaultData(variables: [_variable()]));

      final reopened = await vaultWith(await cipher());
      expect(reopened.data.protection, EnvProtection.localKey);
      expect(reopened.data.variables.single.value, 'super-secret-value');
    });

    test('the value is not readable in the file on disk', () async {
      final vault = await vaultWith(await cipher());
      await vault.save(EnvVaultData(variables: [_variable()]));

      final raw = await File(
        p.join(vaultRoot.path, EnvVault.directoryName, EnvVault.fileName),
      ).readAsString();
      expect(raw, contains('TOKEN'), reason: 'names are not encrypted');
      expect(raw, isNot(contains('super-secret-value')));
      expect(raw, contains('"enc": "local-key"'));
    });

    test('a lost key is reported and the vault refuses to overwrite it',
        () async {
      final vault = await vaultWith(await cipher());
      await vault.save(EnvVaultData(variables: [_variable()]));
      final file = File(
        p.join(vaultRoot.path, EnvVault.directoryName, EnvVault.fileName),
      );
      final before = await file.readAsString();

      // The cache directory was cleared; a fresh key is generated.
      await File(
        p.join(keyDir.path, LocalKeyEnvValueCipher.keyFileName),
      ).delete();
      final reopened = await vaultWith(await cipher());

      expect(reopened.data.variables, isEmpty);
      expect(reopened.data.problem, contains('could not be decrypted'));
      expect(reopened.isReadOnly, isTrue);

      await expectLater(
        reopened.save(const EnvVaultData()),
        throwsA(isA<EnvVaultRefusal>()),
      );
      expect(
        await file.readAsString(),
        before,
        reason: 'unreadable values must survive, not be written over',
      );
    });

    test('a plaintext vault is not silently read as an encrypted one',
        () async {
      final plain = EnvVault(
        directory: Directory(p.join(vaultRoot.path, EnvVault.directoryName)),
        permissions: _FakePermissions(),
      );
      await plain.load();
      await plain.save(EnvVaultData(variables: [_variable()]));

      final encrypted = await vaultWith(await cipher());
      expect(encrypted.data.variables, isEmpty);
      expect(encrypted.data.problem, contains('different version'));
      expect(encrypted.isReadOnly, isTrue);
    });
  });
}
