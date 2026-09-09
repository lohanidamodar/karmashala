import 'dart:io';

import 'package:agent_cli/process.dart';
import 'package:karmashala/src/features/mcp/mcp_bridge_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_command_runner.dart';
import '../../support/temp_directory.dart';

/// Whether an agent can actually get tools out of this app, asked properly.
///
/// The check this replaces was `File.existsSync`, and on 2026-09-03 it reported
/// "Tools available" for over an hour while WSL's interop handler was gone and
/// nothing could spawn the perfectly good file it had found. These four cases
/// are the four answers that need four different responses from the user.
void main() {
  late Directory temp;
  late File bridge;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('bridge_probe');
    bridge = File('${temp.path}/karmashala_mcp')..writeAsStringSync('');
  });
  tearDown(() => removeTempDirectory(temp));

  McpBridgeProbe probeWith(
    FakeCommandRunner runner, {
    File? Function()? locate,
    Duration timeout = const Duration(milliseconds: 200),
  }) => McpBridgeProbe(
    runner: runner,
    bridgeExecutable: locate ?? () => bridge,
    timeout: timeout,
  );

  /// The reply the real bridge writes: it answers `initialize` out of its own
  /// code, without touching the app, which is why this probe separates "the
  /// bridge runs" from "the app answers it".
  const initializeResult =
      '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05",'
      '"capabilities":{"tools":{}},'
      '"serverInfo":{"name":"karmashala","version":"1.0.0"}}}';

  test('answering: the bridge spawns and completes the handshake', () async {
    late FakeProcessHandle handle;
    final runner = FakeCommandRunner(
      processFactory: (_) {
        handle = FakeProcessHandle();
        Future.microtask(() => handle.emitStdout(initializeResult));
        return handle;
      },
    );

    final result = await probeWith(runner).probe();

    expect(result.verdict, McpBridgeVerdict.answering);
    expect(result.detail, 'server karmashala 1.0.0, protocol 2024-11-05');
    expect(result.path, bridge.path);
    expect(runner.startRequests.single.executable, bridge.path);
    // A real `initialize`, not a ping: this is the handshake a client opens
    // with, so the probe proves the same path a client takes.
    expect(handle.written.single, contains('"method":"initialize"'));
    // Nothing is left running. The bridge is a long-lived server and would
    // otherwise accumulate one process per check.
    expect(handle.killed, isTrue);
  });

  test('unspawnable: the file is there and the machine refuses it', () async {
    // Today's failure, as `posix_spawn` reported it once the WSLInterop binfmt
    // handler had disappeared.
    final runner = FakeCommandRunner(
      throwError: CommandException(
        'Failed to start "${bridge.path}" on windows',
        cause: const ProcessException(
          'karmashala_mcp.exe',
          [],
          'ENOEXEC: unknown error',
          8,
        ),
      ),
    );

    final result = await probeWith(runner).probe();

    expect(result.verdict, McpBridgeVerdict.unspawnable);
    expect(result.path, bridge.path);
    expect(result.detail, contains('ENOEXEC'));
  });

  test('absent: there is nothing beside the app to spawn', () async {
    final runner = FakeCommandRunner();

    final result = await probeWith(runner, locate: () => null).probe();

    expect(result.verdict, McpBridgeVerdict.absent);
    expect(result.path, isNull);
    // Nothing was started, so nothing can be claimed about spawning.
    expect(runner.startRequests, isEmpty);
  });

  group('no handshake', () {
    test('a process that never answers times out', () async {
      final runner = FakeCommandRunner(
        processFactory: (_) => FakeProcessHandle(),
      );

      final result = await probeWith(runner).probe();

      expect(result.verdict, McpBridgeVerdict.noHandshake);
      expect(result.detail, 'No reply within 0s.');
    });

    test('a process that exits before answering says so', () async {
      final runner = FakeCommandRunner(
        processFactory: (_) {
          final handle = FakeProcessHandle();
          Future.microtask(() => handle.complete(3));
          return handle;
        },
      );

      final result = await probeWith(runner).probe();

      expect(result.verdict, McpBridgeVerdict.noHandshake);
      expect(result.detail, contains('exited with code 3'));
    });

    test('a process that answers with something that is not MCP', () async {
      final runner = FakeCommandRunner(
        processFactory: (_) {
          final handle = FakeProcessHandle();
          Future.microtask(() => handle.emitStdout('Usage: karmashala_mcp'));
          return handle;
        },
      );

      final result = await probeWith(runner).probe();

      expect(result.verdict, McpBridgeVerdict.noHandshake);
      expect(result.detail, contains('not JSON'));
    });

    test('a JSON-RPC error is a refusal, not a pass', () async {
      final runner = FakeCommandRunner(
        processFactory: (_) {
          final handle = FakeProcessHandle();
          Future.microtask(
            () => handle.emitStdout(
              '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,'
              '"message":"Method not found: initialize"}}',
            ),
          );
          return handle;
        },
      );

      final result = await probeWith(runner).probe();

      expect(result.verdict, McpBridgeVerdict.noHandshake);
      expect(result.detail, contains('Method not found'));
    });

    test('a well-formed reply that is not an initialize result', () async {
      final runner = FakeCommandRunner(
        processFactory: (_) {
          final handle = FakeProcessHandle();
          Future.microtask(
            () => handle.emitStdout('{"jsonrpc":"2.0","id":1,"result":{}}'),
          );
          return handle;
        },
      );

      final result = await probeWith(runner).probe();

      expect(result.verdict, McpBridgeVerdict.noHandshake);
      expect(result.detail, contains('not with an MCP initialize result'));
    });
  });

  test('the probe reports how long it took', () async {
    final runner = FakeCommandRunner(
      processFactory: (_) {
        final handle = FakeProcessHandle();
        Future.microtask(() => handle.emitStdout(initializeResult));
        return handle;
      },
    );

    final result = await probeWith(runner).probe();

    expect(result.took, isNotNull);
    expect(result.took.isNegative, isFalse);
  });
}
