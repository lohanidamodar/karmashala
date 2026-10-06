import 'dart:convert';
import 'dart:io';

import 'package:karmashala_host/src/automations/webhooks/server_hook_vault.dart';
import 'package:karmashala_mcp/access.dart' show HandshakePermissions;
import 'package:karmashala_relay_protocol/karmashala_relay_protocol.dart';
import 'package:test/test.dart';

class _Permissions extends HandshakePermissions {
  const _Permissions({this.allow = true});
  final bool allow;
  @override
  Future<bool> restrictDirectory(Directory dir, {Object? logger}) async =>
      allow;
  @override
  Future<bool> restrictFile(File file, {Object? logger}) async => allow;
}

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('hook_vault_'));
  tearDown(() => temp.deleteSync(recursive: true));

  ServerHookVault vault({bool allow = true}) => ServerHookVault(
    dataDirectory: temp.path,
    permissions: _Permissions(allow: allow),
  );

  test('the listen key is made once, from a CSPRNG, and kept', () async {
    final first = await vault().listenKey();
    expect(hooksListenKeyPattern.hasMatch(first), isTrue);
    expect(await vault().listenKey(), first);
  });

  test('callers racing for the key get one key, and only once it is on '
      'disk', () async {
    final v = vault();
    final rotating = v.rotate('h1');
    final a = v.listenKey();
    final b = v.listenKey();
    await rotating;
    final keys = await Future.wait([a, b]);
    expect(keys.toSet(), hasLength(1));
    expect(vault().heldListenKey, keys.first);
  });

  test('a rotated secret replaces the old one at once and persists', () async {
    final v = vault();
    final one = await v.rotate('h1');
    expect(v.secretOf('h1'), one);
    final two = await v.rotate('h1');
    expect(two, isNot(one));
    expect(v.secretOf('h1'), two);
    expect(vault().secretOf('h1'), two);
  });

  test('a forgotten hook has no secret', () async {
    final v = vault();
    await v.rotate('h1');
    await v.forget('h1');
    expect(v.secretOf('h1'), isNull);
    expect(vault().secretOf('h1'), isNull);
  });

  test('lives in secrets/hooks.json, owner-only, or is not written', () async {
    await vault().rotate('h1');
    final file = File('${temp.path}/secrets/hooks.json');
    expect(file.existsSync(), isTrue);
    expect(jsonDecode(file.readAsStringSync()), isA<Map<String, Object?>>());
    final refused = vault(allow: false);
    await expectLater(refused.rotate('h2'), throwsA(isA<StateError>()));
    expect(vault().secretOf('h2'), isNull);
  });

  test('an unreadable file refuses writes rather than overwrite it', () async {
    Directory('${temp.path}/secrets').createSync();
    File('${temp.path}/secrets/hooks.json').writeAsStringSync('{broken');
    final v = vault();
    expect(v.secretOf('h1'), isNull);
    await expectLater(v.rotate('h1'), throwsA(isA<StateError>()));
    expect(
      File('${temp.path}/secrets/hooks.json').readAsStringSync(),
      '{broken',
    );
  });

  test('its toString names no secret', () async {
    final v = vault();
    final secret = await v.rotate('h1');
    expect('$v', isNot(contains(secret)));
  });
}
