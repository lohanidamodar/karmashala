import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _schema(String name) =>
    LauncherControlServer.toolSchemas.firstWhere((s) => s['name'] == name);

void main() {
  group('session_handoff', () {
    test('requires the session and the instruction, and nothing else', () {
      final input =
          _schema('session_handoff')['inputSchema'] as Map<String, dynamic>;
      // The instruction is required because it is the only part of the packet
      // a model cannot infer from the session it is reading.
      expect(input['required'], ['sessionId', 'instruction']);
      expect(
        (input['properties'] as Map).keys,
        containsAll([
          'sessionId',
          'cli',
          'agentInstallationId',
          'instruction',
          'unresolved',
          'newWorktree',
          'preview',
        ]),
      );
    });

    test('the description states the facts a caller would otherwise guess', () {
      final description = _schema('session_handoff')['description'] as String;
      // Same worktree and branch by default — the thing a model would get
      // wrong, because "start a session" usually means somewhere fresh.
      expect(description, contains('SAME worktree'));
      expect(description, contains('SAME branch'));
      // Provenance, which is the whole point of the packet.
      expect(description, contains('states its provenance'));
      expect(description, contains('not its own'));
      // And that the original is untouched, so a model does not tidy it away.
      expect(description, contains('left running and untouched'));
    });
  });

  group('session_fork', () {
    test('takes only the session, everything else optional', () {
      final input =
          _schema('session_fork')['inputSchema'] as Map<String, dynamic>;
      expect(input['required'], ['sessionId']);
      expect(
        (input['properties'] as Map).keys,
        containsAll(['sessionId', 'instruction', 'newWorktree', 'preview']),
      );
    });

    test('says a fork keeps the same agent and may degrade to a handoff', () {
      final description = _schema('session_fork')['description'] as String;
      expect(description, contains('SAME agent'));
      expect(description, contains('not a change of provider'));
      // The degradation is named in the tool's own description, so a model
      // reads it before calling rather than being surprised by the result.
      expect(description, contains('falls back to a handoff packet'));
      expect(description, contains('says which happened'));
    });
  });

  test('both tools offer a preview that starts nothing', () {
    for (final name in ['session_handoff', 'session_fork']) {
      final properties =
          (_schema(name)['inputSchema'] as Map<String, dynamic>)['properties']
              as Map<String, dynamic>;
      final preview = properties['preview'] as Map<String, dynamic>;
      expect(preview['type'], 'boolean');
      expect(preview['description'], contains('without starting anything'));
    }
  });
}
