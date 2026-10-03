@Tags(['live-acp'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:test/test.dart';

/// Runs the real Claude ACP adapter (`npx -y @agentclientprotocol/
/// claude-agent-acp`) inside WSL and holds one trivial turn with it. Opt-in:
/// it spends a model turn and needs WSL, npx and a Claude login, so it skips
/// itself unless KARMASHALA_LIVE_ACP=1 is set and WSL answers `command -v
/// npx`. It is the one check no fake can stand in for: that the framing,
/// the handshake and the update vocabulary are what a shipped agent speaks.
String? liveSkipReason() {
  if (Platform.environment['KARMASHALA_LIVE_ACP'] != '1') {
    return 'set KARMASHALA_LIVE_ACP=1 to run against the real adapter';
  }
  if (!Platform.isWindows) return 'drives the adapter through wsl.exe';
  try {
    final probe = Process.runSync('wsl.exe', [
      '-e',
      'bash',
      '-lc',
      'command -v npx',
    ]);
    if (probe.exitCode != 0) return 'WSL has no npx on its login PATH';
  } on ProcessException catch (e) {
    return 'wsl.exe is not available: ${e.message}';
  }
  return null;
}

class _AllowFirst extends AcpClientHandler {
  const _AllowFirst();

  @override
  Future<PermissionOutcome> requestPermission(
    String sessionId,
    ToolCallUpdate toolCall,
    List<PermissionOption> options,
  ) async => PermissionOutcome.selected(
    options
        .firstWhere((o) => o.kind.allows, orElse: () => options.first)
        .optionId,
  );

  @override
  Future<String> readTextFile(
    String sessionId,
    String path, {
    int? line,
    int? limit,
  }) => throw const AcpRpcError(JsonRpcErrorCodes.resourceNotFound, 'no fs');

  @override
  Future<void> writeTextFile(String sessionId, String path, String content) =>
      throw const AcpRpcError(JsonRpcErrorCodes.resourceNotFound, 'no fs');
}

void main() {
  final skip = liveSkipReason();

  test(
    'claude-agent-acp in WSL: initialize, session/new in a temp folder, one '
    'prompt yields a message chunk and a stop reason',
    () async {
      final cwd = (await Process.run('wsl.exe', [
        '-e',
        'bash',
        '-lc',
        'mktemp -d',
      ])).stdout.toString().trim();
      expect(cwd, startsWith('/'));
      final process = await Process.start('wsl.exe', [
        '-e',
        'bash',
        '-lc',
        'npx -y @agentclientprotocol/claude-agent-acp',
      ]);
      final stderr = StringBuffer();
      process.stderr.transform(utf8.decoder).listen(stderr.write);
      final peer = AcpPeer(process.stdout, process.stdin);
      peer.malformed.listen((m) => stderr.writeln('[malformed] $m'));
      final client = AcpAgentClient(peer, handler: const _AllowFirst());
      try {
        final init = await client.initialize(
          clientInfo: const ClientInfo(name: 'Karmashala', version: 'test'),
        );
        expect(init.protocolVersion, 1);
        final session = await client.newSession(cwd: cwd);
        expect(session.sessionId, isNotEmpty);
        final chunks = <AgentMessageChunk>[];
        client.updates.listen((e) {
          if (e.update case final AgentMessageChunk chunk) chunks.add(chunk);
        });
        final reason = await client.prompt(session.sessionId, const [
          ContentBlock.text('Reply with the single word: pong'),
        ]);
        expect(reason.isKnown, isTrue, reason: 'stop reason ${reason.raw}');
        expect(chunks, isNotEmpty, reason: 'stderr: $stderr');
      } finally {
        await client.close();
        process.kill();
        await Process.run('wsl.exe', ['-e', 'bash', '-lc', 'rm -rf "$cwd"']);
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
