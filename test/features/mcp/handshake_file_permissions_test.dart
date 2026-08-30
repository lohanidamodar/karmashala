import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/features/mcp/handshake_file_permissions.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The handshake file publishes the two bearer tokens that are the *entire*
/// access-control boundary for the launcher control server — loopback TCP lets
/// any local process connect and attempt auth, so the file's permissions are
/// what keep another account on the machine out.
///
/// These assertions read the real ACL that the real code path produced, via the
/// SDDL, which names principals by SID and so does not care about the machine's
/// display language.
void main() {
  /// Well-known SIDs in SDDL shorthand that must never appear in the file's
  /// DACL: Everyone, BUILTIN\Users, Authenticated Users, INTERACTIVE.
  const broadPrincipals = ['WD', 'BU', 'AU', 'IU'];

  Future<String> sddlOf(String path) async {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-Command',
      "(Get-Acl -LiteralPath '$path').Sddl",
    ]);
    expect(result.exitCode, 0, reason: 'Get-Acl failed: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  group('restrictHandshakeFileToCurrentUser', () {
    late Directory tmp;

    setUp(() => tmp = Directory.systemTemp.createTempSync('chitra_acl_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('locks a file to the current user and stops inheriting', () async {
      final file = File(p.join(tmp.path, 'mcp_bridge.json'))
        ..writeAsStringSync('{}');

      expect(await restrictHandshakeFileToCurrentUser(file), isTrue);

      final sddl = await sddlOf(file.path);
      // "P" on the DACL is the protected flag: inherited ACEs are gone and a
      // broad ACE added to %APPDATA% or an ancestor can no longer reach here.
      expect(sddl, contains('D:P'));
      for (final sid in broadPrincipals) {
        expect(sddl, isNot(contains(';$sid)')), reason: '$sid must not appear');
      }
      // The owner keeps full access — a lockout would be worse than the risk.
      expect(file.readAsStringSync(), '{}');
      file.writeAsStringSync('{"still":"writable"}');
    });

    test('a file under a deliberately loosened parent is still locked down', () {
      // The scenario the fix exists for: a parent folder that grants Everyone,
      // which the handshake file would otherwise silently inherit.
      final loose = Directory(p.join(tmp.path, 'loose'))..createSync();
      final grant = Process.runSync('icacls', [
        loose.path,
        '/grant',
        '*S-1-1-0:(OI)(CI)(F)',
      ]);
      expect(grant.exitCode, 0, reason: '${grant.stderr}');

      final file = File(p.join(loose.path, 'mcp_bridge.json'))
        ..writeAsStringSync('{}');
      // Sanity: it really did inherit the loose ACE before we intervene.
      expect(Process.runSync('icacls', [file.path]).stdout, contains('(I)'));

      expect(restrictHandshakeFileToCurrentUser(file), completion(isTrue));
    });
  }, skip: Platform.isWindows ? false : 'Windows ACLs');

  group('the handshake file the server actually writes', () {
    late Directory tmp;
    late ProviderContainer container;
    late LauncherControlServer server;
    late String path;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('chitra_handshake_');
      path = p.join(tmp.path, 'mcp_bridge.json');
      container = ProviderContainer();
      server = LauncherControlServer(container);
      // A real socket directory inside the temp folder. Without one the server
      // falls back to `getApplicationSupportDirectory()`, which no plugin
      // answers under `flutter test`; since Loop 61 a socket that cannot be
      // brought up withholds the privileged token entirely, so these
      // assertions would be reading a handshake that deliberately has none.
      await server.start(
        bridgeFilePath: path,
        socketDirectory: p.join(tmp.path, 'ipc'),
      );
    });

    tearDown(() async {
      await server.stop();
      container.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('is readable by nobody but this user', () async {
      final sddl = await sddlOf(path);
      expect(sddl, contains('D:P'));
      for (final sid in broadPrincipals) {
        expect(sddl, isNot(contains(';$sid)')), reason: '$sid must not appear');
      }
    }, skip: Platform.isWindows ? false : 'Windows ACLs');

    test('carries two distinct, high-entropy tokens', () async {
      final json =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      final rpc = json['token'] as String;
      final hook = json['hookToken'] as String;

      expect(rpc, isNot(hook));
      // 24 random bytes, base64url — 192 bits from Random.secure().
      for (final token in [rpc, hook]) {
        expect(base64Url.decode(token), hasLength(24));
      }
    });

    test('restarting mints fresh tokens', () async {
      final first =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      await server.stop();
      await server.start(bridgeFilePath: path);
      final second =
          jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

      expect(second['token'], isNot(first['token']));
      expect(second['hookToken'], isNot(first['hookToken']));
    });
  });
}
