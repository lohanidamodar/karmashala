import 'dart:convert';
import 'dart:io';

import 'package:chitragupta/src/core/database/app_database.dart';
import 'package:chitragupta/src/core/database/database_providers.dart';
import 'package:chitragupta/src/core/util/clock_provider.dart';
import 'package:chitragupta/src/features/mcp/handshake_file_permissions.dart';
import 'package:chitragupta/src/features/mcp/launcher_control_server.dart';
import 'package:chitragupta/src/features/mcp/launcher_mcp.dart';
import 'package:chitragupta/src/core/logging/app_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The config that tells an agent where the tools are, and the identity that
/// travels in it.
///
/// The URL is the identity mechanism on the HTTP side, so the assertions that
/// matter are: a session's URL names that session to the server, two sessions
/// never get the same one, and nothing is offered at all when the endpoint
/// could not be secured.
void main() {
  late Directory tmp;
  late AppDatabase db;
  late ProviderContainer container;
  late LauncherControlServer server;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('chitra_mcp_config_');
    db = AppDatabase.memory();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    server = LauncherControlServer(container);
    await server.start(
      bridgeFilePath: p.join(tmp.path, 'mcp_bridge.json'),
      socketDirectory: p.join(tmp.path, 'ipc'),
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('the URL carries who is calling', () {
    test('a session\'s URL resolves back to that session', () async {
      final url = server.mcpUrlFor('s1')!;
      final token = Uri.parse(url).pathSegments.last;

      expect(server.callers.sessionFor(token), 's1');
    });

    test('two sessions never share a URL', () {
      expect(server.mcpUrlFor('s1'), isNot(server.mcpUrlFor('s2')));
    });

    test('a session\'s URL is stable, so a rewritten config still works', () {
      expect(server.mcpUrlFor('s1'), server.mcpUrlFor('s1'));
    });

    test('the unattributed URL names no session', () {
      final token = Uri.parse(server.mcpUrl!).pathSegments.last;
      expect(server.callers.sessionFor(token), isNull);
    });

    test('a retired session\'s token stops speaking for it', () {
      final token = Uri.parse(server.mcpUrlFor('s1')!).pathSegments.last;
      server.callers.forget('s1');
      expect(server.callers.sessionFor(token), isNull);
    });
  });

  group('the written config', () {
    test('points at the HTTP endpoint when there is one', () async {
      final path = await const LauncherMcp().ensureConfig(
        url: server.mcpUrlFor('s1'),
        directory: tmp.path,
      );

      final config =
          jsonDecode(File(path!).readAsStringSync()) as Map<String, Object?>;
      final entry =
          (config['mcpServers']! as Map<String, Object?>)['chitragupta']!
              as Map<String, Object?>;

      expect(entry['type'], 'http');
      expect(entry['url'], server.mcpUrlFor('s1'));
      // The credential is in the URL, not in headers: Claude Code does not
      // attach configured headers to a Streamable HTTP server's requests.
      expect(entry.containsKey('headers'), isFalse);
      expect(entry.containsKey('command'), isFalse);
    });

    test('a per-session file does not overwrite another session\'s', () async {
      await const LauncherMcp().ensureConfig(
        url: server.mcpUrlFor('s1'),
        directory: tmp.path,
        fileName: 's1.json',
      );
      await const LauncherMcp().ensureConfig(
        url: server.mcpUrlFor('s2'),
        directory: tmp.path,
        fileName: 's2.json',
      );

      String urlIn(String file) {
        final config =
            jsonDecode(File(p.join(tmp.path, file)).readAsStringSync())
                as Map<String, Object?>;
        return ((config['mcpServers']! as Map<String, Object?>)['chitragupta']!
                as Map<String, Object?>)['url']!
            as String;
      }

      expect(urlIn('s1.json'), isNot(urlIn('s2.json')));
      expect(
        server.callers.sessionFor(Uri.parse(urlIn('s1.json')).pathSegments.last),
        's1',
      );
      expect(
        server.callers.sessionFor(Uri.parse(urlIn('s2.json')).pathSegments.last),
        's2',
      );
    });

    test('offers nothing when there is no URL and no bridge', () async {
      // A dev run: no compiled bridge beside the binary, and no URL given.
      // Writing a config pointing at nothing would be worse than none.
      expect(
        await const LauncherMcp().ensureConfig(directory: tmp.path),
        isNull,
      );
    });

    test('Codex gets the same URL in the shape its TOML wants', () {
      final url = server.mcpUrlFor('s1')!;
      final toml = LauncherMcp.codexServerToml(url);

      expect(toml, contains('[mcp_servers.chitragupta]'));
      expect(toml, contains('url = "$url"'));
      // No bearer_token_env_var: the credential is already in the URL, so
      // nothing has to be put on the process environment for Codex to read.
      expect(toml, isNot(contains('bearer_token_env_var')));
    });
  });

  group('the pre-approval lists come from the one registry', () {
    test('every served tool is nameable', () {
      expect(
        LauncherMcp.allowedTools,
        hasLength(LauncherControlServer.toolSchemas.length),
      );
      expect(LauncherMcp.allowedTools, contains('mcp__chitragupta__list_sessions'));
    });

    test('the read-only list matches the annotations clients are served', () {
      expect(
        LauncherMcp.readOnlyTools,
        contains('mcp__chitragupta__list_sessions'),
      );
      // A tool that ends something must never be on a pre-approval list built
      // from readOnlyHint.
      expect(
        LauncherMcp.readOnlyTools,
        isNot(contains('mcp__chitragupta__session_end')),
      );
      expect(
        LauncherMcp.readOnlyTools,
        isNot(contains('mcp__chitragupta__terminal_run')),
      );
      expect(
        LauncherMcp.readOnlyTools.length,
        lessThan(LauncherMcp.allowedTools.length),
      );
    });
  });

  test('no URL is offered when the endpoint could not be secured', () async {
    final other = Directory.systemTemp.createTempSync('chitra_mcp_closed_');
    addTearDown(() {
      if (other.existsSync()) other.deleteSync(recursive: true);
    });
    final closedDb = AppDatabase.memory();
    addTearDown(closedDb.close);
    final closedContainer = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(closedDb),
        clockProvider.overrideWithValue(FixedClock(testTime)),
      ],
    );
    final closed = LauncherControlServer(
      closedContainer,
      permissions: _RefusingPermissions(),
    );
    await closed.start(
      bridgeFilePath: p.join(other.path, 'mcp_bridge.json'),
      socketDirectory: p.join(other.path, 'ipc'),
    );
    addTearDown(() async {
      await closed.stop();
      closedContainer.dispose();
    });

    // Fail closed all the way out to the config: an agent is not handed a URL
    // that answers 401 to everything.
    expect(closed.mcpUrl, isNull);
    expect(closed.mcpUrlFor('s1'), isNull);
  });
}

class _RefusingPermissions extends HandshakePermissions {
  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      false;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => false;
}
