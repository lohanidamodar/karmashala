import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_mcp/instructions.dart';
import 'package:test/test.dart';

const _noArguments = <String, dynamic>{};

bool _gated(
  String tool, [
  Map<String, dynamic> arguments = _noArguments,
  String? caller = 'me',
]) => mcpToolNeedsOperatorGrant(tool, arguments, caller);

void main() {
  group('tools that reach other sessions and agents', () {
    test('are always gated', () {
      for (final tool in const [
        'open_new_session',
        'open_session',
        'subagent_run',
        'session_send',
        'session_answer',
        'session_end',
        'session_handoff',
        'session_fork',
        'session_fork_from_checkpoint',
        'session_rewind',
        'delegation_set_report',
        'delegation_detach',
        'pipeline_run',
        'pipeline_approve',
        'worktree_remove',
        'snippet_insert',
      ]) {
        expect(kMcpOperatorTools, contains(tool));
        expect(_gated(tool), isTrue, reason: tool);
        expect(_gated(tool, {'sessionId': 'me'}), isTrue, reason: tool);
      }
    });

    test('every one is a tool the catalogue knows', () {
      expect(kMcpToolAnnotations.keys, containsAll(kMcpOperatorTools));
    });
  });

  group('tools aimed at a session', () {
    const tools = [
      'session_rename',
      'session_draft',
      'session_checkout_attach',
      'session_checkout_detach',
    ];

    test('are free on the caller itself', () {
      for (final tool in tools) {
        expect(_gated(tool), isFalse, reason: '$tool, no id');
        expect(_gated(tool, {'sessionId': 'me'}), isFalse, reason: tool);
        expect(_gated(tool, {'sessionId': ' me '}), isFalse, reason: tool);
        // A blank id falls back to the caller in every one of these tools.
        expect(_gated(tool, {'sessionId': '  '}), isFalse, reason: tool);
      }
    });

    test('are gated on any other session', () {
      for (final tool in tools) {
        expect(_gated(tool, {'sessionId': 'other'}), isTrue, reason: tool);
      }
    });

    test('are gated when the id cannot be read as one', () {
      for (final tool in tools) {
        expect(_gated(tool, {'sessionId': 7}), isTrue, reason: tool);
      }
    });
  });

  group('terminal_close', () {
    test('is free when it detaches', () {
      expect(_gated('terminal_close', {'tabId': 't'}), isFalse);
      expect(_gated('terminal_close', {'tabId': 't', 'kill': false}), isFalse);
    });

    test('is gated when it kills, which can end agents', () {
      expect(_gated('terminal_close', {'tabId': 't', 'kill': true}), isTrue);
    });
  });

  group('checkpoint_restore', () {
    bool restore(String id, {String? Function(String)? owner}) =>
        mcpToolNeedsOperatorGrant(
          'checkpoint_restore',
          {'id': id},
          'me',
          checkpointOwner: owner,
        );

    test('is free on the caller\'s own checkpoint', () {
      expect(restore('c1', owner: (_) => 'me'), isFalse);
    });

    test('is gated on another session\'s checkpoint', () {
      expect(restore('c1', owner: (_) => 'other'), isTrue);
    });

    test('is gated when nothing can say whose checkpoint it is', () {
      expect(restore('c1', owner: (_) => null), isTrue);
      expect(restore('c1'), isTrue);
    });
  });

  test('a tool the catalogue does not know stays gated', () {
    expect(_gated('no_such_tool'), isTrue);
  });

  test('everything else leaves the gate', () {
    for (final tool in const [
      'device_tap',
      'device_install_app',
      'browser_click',
      'browser_evaluate',
      'flutter_run',
      'project_build',
      'checks_run',
      'project_add',
      'project_update',
      'worktree_create',
      'webhook_create',
      'automation_propose',
      'inbox_dismiss',
      'terminal_open',
      'terminal_run',
      'note_delete',
      'todo_delete',
      'report_to_parent',
      'request_secret',
    ]) {
      expect(_gated(tool), isFalse, reason: tool);
    }
  });

  test('session_archive keeps its own rule and not this gate', () {
    expect(_gated('session_archive', {'sessionId': 'other'}), isFalse);
    expect(_gated('session_unarchive', {'sessionId': 'other'}), isFalse);
  });

  test('every catalogued tool has an answer without its arguments', () {
    for (final tool in kMcpToolAnnotations.keys) {
      expect(() => _gated(tool), returnsNormally, reason: tool);
    }
  });

  test('the sessions guide says what the grant covers, and is no sandbox', () {
    final sessions = kMcpGuides.firstWhere((g) => g.topic == 'sessions');
    expect(sessions.body, contains('Operate Karmashala'));
    expect(sessions.body, contains('other sessions and agents'));
    expect(sessions.body, contains('not a sandbox'));
  });

  group('the refusal', () {
    final text = mcpOperatorRefusal('session_send');

    test('says nothing was done and how the person gives the grant', () {
      expect(text, contains('NOTHING WAS DONE'));
      expect(text, contains('Operate Karmashala'));
      expect(text, contains('/operator'));
    });

    test('names what the grant covers', () {
      expect(text, contains('other sessions and agents'));
    });

    test('tells the agent what still works', () {
      expect(text, contains('devices'));
      expect(text, contains('browser'));
      expect(text, contains('builds'));
    });
  });
}
