import 'dart:io';

import 'package:karmashala/src/core/database/app_database.dart';
import 'package:karmashala/src/core/database/database_providers.dart';
import 'package:karmashala/src/core/util/clock_provider.dart';
import 'package:karmashala/src/features/environments/domain/environment_kind.dart';
import 'package:karmashala/src/features/mcp/handshake_file_permissions.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/launcher_mcp.dart';
import 'package:karmashala/src/core/logging/app_logger.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fakes.dart';
import '../../support/fixtures.dart';

/// The identity that travels in the URL an agent is pointed at, and the
/// plumbing around it that was deleted rather than finished.
///
/// The URL is the identity mechanism on the HTTP side, so the assertions that
/// matter are: a session's URL names that session to the server, two sessions
/// never get the same one, and nothing is offered at all when the endpoint
/// could not be secured. The file an agent actually opens is
/// `session_mcp_config_test.dart`'s subject.
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
      // No second interface: this file is about the URL's *contents*, and the
      // address per environment is `mcp_reachability_test.dart`'s subject.
      wslHostAddress: () async => null,
    );
  });

  tearDown(() async {
    await server.stop();
    container.dispose();
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// The URL a Windows-native pane is given. The address per environment is
  /// `mcp_reachability_test.dart`'s subject; here it is only a way to get one.
  String? urlFor(String sessionId) =>
      server.mcpUrlFor(sessionId, environment: EnvironmentKind.windowsNative);

  group('the URL carries who is calling', () {
    test('a session\'s URL resolves back to that session', () async {
      final url = urlFor('s1')!;
      final token = Uri.parse(url).pathSegments.last;

      expect(server.callers.sessionFor(token), 's1');
    });

    test('two sessions never share a URL', () {
      expect(urlFor('s1'), isNot(urlFor('s2')));
    });

    test('a session\'s URL is stable, so a rewritten config still works', () {
      expect(urlFor('s1'), urlFor('s1'));
    });

    test('the unattributed URL names no session', () {
      final token = Uri.parse(server.mcpUrl!).pathSegments.last;
      expect(server.callers.sessionFor(token), isNull);
    });

    test('a retired session\'s token stops speaking for it', () {
      final token = Uri.parse(urlFor('s1')!).pathSegments.last;
      server.callers.forget('s1');
      expect(server.callers.sessionFor(token), isNull);
    });
  });

  test('the HTTP entry puts the credential in the URL, not in headers', () {
    // Claude Code does not attach configured headers to a Streamable HTTP
    // server's requests, so a token in `headers` never arrives.
    final entry = LauncherMcp.httpServerEntry(urlFor('s1')!);

    expect(entry['type'], 'http');
    expect(entry['url'], urlFor('s1'));
    expect(entry.containsKey('headers'), isFalse);
    expect(entry.containsKey('command'), isFalse);
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
      wslHostAddress: () async => null,
    );
    addTearDown(() async {
      await closed.stop();
      closedContainer.dispose();
    });

    // Fail closed all the way out to the config: an agent is not handed a URL
    // that answers 401 to everything.
    expect(closed.mcpUrl, isNull);
    expect(
      closed.mcpUrlFor('s1', environment: EnvironmentKind.windowsNative),
      isNull,
    );
  });

  group('the plumbing that was deleted stays deleted', () {
    // Read off the source rather than the symbol table on purpose: a symbol
    // that is gone cannot be referenced in a test, so nothing else in the
    // suite can notice it coming back. Each name below was removed for a
    // reason recorded at its old site, and re-adding one silently is how the
    // reason gets lost.
    // Comments are stripped, as `ui_token_debt_test` does: a name quoted in
    // prose is the record of why it went, not a reference to it.
    final sources = <String, String>{
      for (final file
          in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart'))
          file.path.replaceAll(r'\', '/'): file
              .readAsStringSync()
              .split('\n')
              .map((line) {
                final comment = line.indexOf('//');
                return comment == -1 ? line : line.substring(0, comment);
              })
              .join('\n'),
    };

    List<String> mentioning(String name) => [
      for (final entry in sources.entries)
        if (entry.value.contains(name)) entry.key,
    ];

    test('nothing writes an MCP config outside SessionMcpConfigs', () {
      // `LauncherMcp.ensureConfig` wrote one shared file for a caller — the
      // launcher chat — that was deleted with mini mode. Per-session configs
      // are `SessionMcpConfigs.write`'s job, because the URL inside one is
      // what says which session is calling.
      expect(mentioning('ensureConfig'), isEmpty);
      expect(mentioning('bridgeServerEntry'), isEmpty);
    });

    test('no Codex TOML is formatted for a file nothing writes', () {
      // Codex is pointed at the endpoint inline, with `-c`, because
      // `~/.codex/config.toml` is machine-wide and cannot be per-session.
      expect(mentioning('codexServerToml'), isEmpty);
    });

    test('no pre-approved tool list exists to be handed to an agent', () {
      // The standing rule: nothing widens what an agent may do without the
      // user's say-so. A list of tool names beside `--permission-mode` does
      // exactly that, which is why neither the lists nor the launch field
      // that would have carried them survive.
      expect(mentioning('allowedTools'), isEmpty);
      expect(mentioning('readOnlyTools'), isEmpty);
    });
  });
}

class _RefusingPermissions extends HandshakePermissions {
  @override
  Future<bool> restrictDirectory(Directory dir, {AppLogger? logger}) async =>
      false;

  @override
  Future<bool> restrictFile(File file, {AppLogger? logger}) async => false;
}
