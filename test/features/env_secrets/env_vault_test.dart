import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_core/logging.dart';
import 'package:karmashala/src/features/env_secrets/data/env_value_cipher.dart';
import 'package:karmashala/src/features/env_secrets/data/env_vault.dart';
import 'package:karmashala/src/features/env_secrets/domain/env_variable.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:path/path.dart' as p;

/// Permissions that answer whatever the test needs, without spawning `icacls`.
///
/// The real tools cannot be made to fail on demand, and "what happens when
/// hardening fails" is the whole security contract here — the same reason
/// `HandshakePermissions` exists as a seam in the first place.
class _FakePermissions extends HandshakePermissions {
  _FakePermissions({this.directoryOk = true});

  final bool directoryOk;
  final List<String> restrictedFiles = [];
  final List<String> restrictedDirectories = [];

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async {
    restrictedFiles.add(file.path);
    return true;
  }

  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async {
    restrictedDirectories.add(dir.path);
    return directoryOk;
  }
}

EnvVariable _variable({
  String id = 'v1',
  String name = 'TOKEN',
  String value = 'super-secret-value',
  bool secret = true,
  bool enabled = true,
}) => EnvVariable(
  id: id,
  name: name,
  value: value,
  secret: secret,
  enabled: enabled,
  updatedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('karmashala_env_vault_test');
  });

  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  EnvVault vaultIn(
    Directory dir, {
    _FakePermissions? permissions,
    EnvValueCipher cipher = const PlaintextEnvValueCipher(),
  }) => EnvVault(
    directory: Directory(p.join(dir.path, EnvVault.directoryName)),
    cipher: cipher,
    permissions: permissions ?? _FakePermissions(),
  );

  group('load', () {
    test('an empty directory yields an empty, writable vault', () async {
      final vault = vaultIn(temp);
      final data = await vault.load();

      expect(data.variables, isEmpty);
      expect(data.enabled, isTrue);
      expect(data.canStoreSecrets, isTrue);
      expect(data.problem, isNull);
    });

    test('the directory is created and hardened before anything is read',
        () async {
      final permissions = _FakePermissions();
      await vaultIn(temp, permissions: permissions).load();

      final dir = Directory(p.join(temp.path, EnvVault.directoryName));
      expect(dir.existsSync(), isTrue);
      expect(permissions.restrictedDirectories, [dir.path]);
    });

    test('a round trip returns the same variables', () async {
      final vault = vaultIn(temp);
      await vault.load();
      await vault.save(
        EnvVaultData(
          variables: [
            _variable(),
            _variable(id: 'v2', name: 'EDITOR', value: 'nvim', secret: false),
          ],
        ),
      );

      final reopened = vaultIn(temp);
      final data = await reopened.load();

      expect(data.variables.map((v) => v.name), ['TOKEN', 'EDITOR']);
      expect(data.variables.first.value, 'super-secret-value');
      expect(data.variables.first.secret, isTrue);
      expect(data.variables.last.secret, isFalse);
    });

    test('the master switch survives a round trip', () async {
      final vault = vaultIn(temp);
      await vault.load();
      await vault.save(const EnvVaultData(enabled: false));

      expect((await vaultIn(temp).load()).enabled, isFalse);
    });

    test('a corrupt file reports a problem and injects nothing', () async {
      final vault = vaultIn(temp);
      await vault.load();
      await vault.save(EnvVaultData(variables: [_variable()]));

      final file = File(
        p.join(temp.path, EnvVault.directoryName, EnvVault.fileName),
      );
      await file.writeAsString('{ this is not json');

      final data = await vaultIn(temp).load();
      expect(data.variables, isEmpty);
      expect(data.problem, isNotNull);
    });

    test('a vault written with an unknown cipher is refused, not guessed at',
        () async {
      final dir = Directory(p.join(temp.path, EnvVault.directoryName))
        ..createSync(recursive: true);
      await File(p.join(dir.path, EnvVault.fileName)).writeAsString(
        jsonEncode({
          'version': 1,
          'enabled': true,
          'enc': 'some-future-cipher',
          'variables': [
            {'id': 'v1', 'name': 'TOKEN', 'secret': true, 'value': 'zzzz'},
          ],
        }),
      );

      final data = await vaultIn(temp).load();
      expect(data.variables, isEmpty);
      expect(data.problem, contains('different version'));
    });

    test('one malformed record does not take the rest of the vault down',
        () async {
      final dir = Directory(p.join(temp.path, EnvVault.directoryName))
        ..createSync(recursive: true);
      await File(p.join(dir.path, EnvVault.fileName)).writeAsString(
        jsonEncode({
          'version': 1,
          'enabled': true,
          'enc': 'none',
          'variables': [
            // Readable, but not a valid variable: the name starts with a
            // digit. Deliberately *decryptable* — a record that will not
            // decrypt is the lost-key case and has the opposite behaviour
            // (see local_key_cipher_test.dart).
            {
              'id': 'bad',
              'name': '9NOT VALID',
              'value': base64.encode(utf8.encode('x')),
            },
            {
              'id': 'good',
              'name': 'KEEP_ME',
              'secret': false,
              'value': base64.encode(utf8.encode('kept')),
            },
          ],
        }),
      );

      final data = await vaultIn(temp).load();
      expect(data.variables.map((v) => v.name), ['KEEP_ME']);
      expect(data.problem, isNull);
    });
  });

  group('fail-closed', () {
    test('a secret is refused when the directory ACL was not applied',
        () async {
      final vault = vaultIn(
        temp,
        permissions: _FakePermissions(directoryOk: false),
      );
      final data = await vault.load();
      expect(data.canStoreSecrets, isFalse);

      await expectLater(
        vault.save(EnvVaultData(variables: [_variable()])),
        throwsA(isA<EnvVaultRefusal>()),
      );
      expect(
        File(
          p.join(temp.path, EnvVault.directoryName, EnvVault.fileName),
        ).existsSync(),
        isFalse,
        reason: 'nothing may be written when the secret was refused',
      );
    });

    test('a plain variable still saves when the ACL was not applied', () async {
      final vault = vaultIn(
        temp,
        permissions: _FakePermissions(directoryOk: false),
      );
      await vault.load();
      final saved = await vault.save(
        EnvVaultData(
          variables: [
            _variable(name: 'EDITOR', value: 'nvim', secret: false),
          ],
        ),
      );

      expect(saved.variables.single.name, 'EDITOR');
      expect(saved.canStoreSecrets, isFalse);
    });

    test('an unavailable vault reports empty and refuses to save', () async {
      final vault = EnvVault.unavailable();
      expect((await vault.load()).variables, isEmpty);
      await expectLater(
        vault.save(EnvVaultData(variables: [_variable()])),
        throwsA(isA<EnvVaultRefusal>()),
      );
    });
  });

  group('writing', () {
    test('the file is restricted every time it is written', () async {
      final permissions = _FakePermissions();
      final vault = vaultIn(temp, permissions: permissions);
      await vault.load();
      await vault.save(EnvVaultData(variables: [_variable()]));

      final target = p.join(
        temp.path,
        EnvVault.directoryName,
        EnvVault.fileName,
      );
      expect(
        permissions.restrictedFiles,
        containsAll(<String>['$target.tmp', target]),
        reason: 'the temp file is hardened before it becomes the vault',
      );
    });

    test('no temp file is left behind', () async {
      final vault = vaultIn(temp);
      await vault.load();
      await vault.save(EnvVaultData(variables: [_variable()]));

      final dir = Directory(p.join(temp.path, EnvVault.directoryName));
      expect(
        dir.listSync().map((e) => p.basename(e.path)),
        [EnvVault.fileName],
      );
    });

    test('a removed variable is gone from the file, not just from memory',
        () async {
      final vault = vaultIn(temp);
      await vault.load();
      await vault.save(EnvVaultData(variables: [_variable()]));
      await vault.save(const EnvVaultData());

      final raw = await File(
        p.join(temp.path, EnvVault.directoryName, EnvVault.fileName),
      ).readAsString();
      expect(raw, isNot(contains('super-secret-value')));
      expect(
        raw,
        isNot(contains(base64.encode(utf8.encode('super-secret-value')))),
      );
    });
  });
}
