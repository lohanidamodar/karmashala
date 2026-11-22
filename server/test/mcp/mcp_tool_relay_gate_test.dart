import 'package:karmashala_host/src/mcp/mcp_tool_relay.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:test/test.dart';

/// Answers every tool it is named for, and records what ran.
class _Recording extends ServerToolSet {
  _Recording(this.names);

  final List<String> names;
  final ran = <String>[];

  @override
  List<Map<String, Object?>> get schemas => [
    for (final name in names) {'name': name},
  ];

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) async {
    ran.add(tool);
    return 'ran';
  }
}

void main() {
  const names = [
    'device_tap',
    'browser_click',
    'project_build',
    'session_send',
    'open_new_session',
    'snippet_insert',
    'session_rename',
    'terminal_close',
    'checkpoint_restore',
    'made_up_tool',
  ];

  late _Recording tools;
  late Set<String> granted;
  late McpToolRelay relay;

  setUp(() {
    tools = _Recording(names);
    granted = {};
    relay = McpToolRelay(
      tools: ServerTools([tools]),
      operatorGranted: granted.contains,
      checkpointOwner: (id) => id == 'mine' ? 'me' : 'someone',
    );
  });

  Matcher refused(String tool) => throwsA(
    isA<McpToolRelayFailure>().having(
      (failure) => failure.message,
      'message',
      allOf(contains(tool), contains('NOTHING WAS DONE')),
    ),
  );

  group('without the grant', () {
    test('a session uses devices, the browser and a build', () async {
      for (final tool in const [
        'device_tap',
        'browser_click',
        'project_build',
      ]) {
        expect(await relay.call(tool, const {}, 'me'), 'ran');
      }
      expect(tools.ran, ['device_tap', 'browser_click', 'project_build']);
    });

    test('it is refused what reaches other sessions and agents', () async {
      for (final tool in const [
        'session_send',
        'open_new_session',
        'snippet_insert',
      ]) {
        await expectLater(
          relay.call(tool, const {}, 'me'),
          refused(tool),
          reason: tool,
        );
      }
      expect(tools.ran, isEmpty);
    });

    test('it renames itself and not another session', () async {
      expect(await relay.call('session_rename', const {}, 'me'), 'ran');
      expect(
        await relay.call('session_rename', {'sessionId': 'me'}, 'me'),
        'ran',
      );
      await expectLater(
        relay.call('session_rename', {'sessionId': 'other'}, 'me'),
        refused('session_rename'),
      );
    });

    test('it detaches a terminal and cannot kill one', () async {
      expect(await relay.call('terminal_close', {'tabId': 't'}, 'me'), 'ran');
      await expectLater(
        relay.call('terminal_close', {'tabId': 't', 'kill': true}, 'me'),
        refused('terminal_close'),
      );
    });

    test('it restores only its own checkpoints', () async {
      expect(
        await relay.call('checkpoint_restore', {'id': 'mine'}, 'me'),
        'ran',
      );
      await expectLater(
        relay.call('checkpoint_restore', {'id': 'theirs'}, 'me'),
        refused('checkpoint_restore'),
      );
    });

    test('a served tool the catalogue does not know is refused', () async {
      await expectLater(
        relay.call('made_up_tool', const {}, 'me'),
        refused('made_up_tool'),
      );
      expect(tools.ran, isEmpty);
    });
  });

  test('with the grant all of it runs', () async {
    granted.add('me');
    for (final tool in names) {
      expect(await relay.call(tool, {'sessionId': 'other'}, 'me'), 'ran');
    }
  });

  test('the grant is the caller\'s, not the named session\'s', () async {
    granted.add('other');
    await expectLater(
      relay.call('session_rename', {'sessionId': 'other'}, 'me'),
      refused('session_rename'),
    );
  });

  test('a caller in no session is the person\'s own tooling', () async {
    expect(await relay.call('session_send', const {}, null), 'ran');
  });

  group('with tool access', () {
    // me and sib are in p1, far in p2.
    const projects = {'me': 'p1', 'sib': 'p1', 'far': 'p2'};
    late McpToolAccessPolicy policy;

    setUp(() {
      tools = _Recording([...names, 'session_answer']);
      policy = McpToolAccessPolicy.defaults;
      relay = McpToolRelay(
        tools: ServerTools([tools]),
        operatorGranted: granted.contains,
        toolAccess: McpToolAccessLookup(
          policy: () => policy,
          projectOf: (id) => projects[id],
          parentOf: (_) => null,
        ),
      );
    });

    test('a session without the grant messages a sibling in its project, '
        'and starts a session', () async {
      expect(
        await relay.call('session_send', {'sessionId': 'sib'}, 'me'),
        'ran',
      );
      expect(await relay.call('open_new_session', const {}, 'me'), 'ran');
    });

    test('another project is refused, with the reason worded', () async {
      await expectLater(
        relay.call('session_send', {'sessionId': 'far'}, 'me'),
        throwsA(
          isA<McpToolRelayFailure>().having(
            (f) => f.message,
            'message',
            allOf(
              contains('session_send'),
              contains('NOTHING WAS DONE'),
              contains('Any project'),
              contains(kMcpToolAccessLocation),
            ),
          ),
        ),
      );
      expect(tools.ran, isEmpty);
    });

    test('session_answer is refused by default, naming its group', () async {
      await expectLater(
        relay.call('session_answer', {'sessionId': 'sib'}, 'me'),
        throwsA(
          isA<McpToolRelayFailure>().having(
            (f) => f.message,
            'message',
            contains('"Answer approvals"'),
          ),
        ),
      );
    });

    test('a change to the policy counts on the next call', () async {
      await expectLater(
        relay.call('snippet_insert', const {}, 'me'),
        refused('snippet_insert'),
      );
      policy = McpToolAccessPolicy(
        global: McpToolAccessOverrides.none.withGroup(McpToolGroup.panes, true),
      );
      expect(await relay.call('snippet_insert', const {}, 'me'), 'ran');
    });

    test('the session grant still wins', () async {
      granted.add('me');
      expect(
        await relay.call('session_answer', {'sessionId': 'far'}, 'me'),
        'ran',
      );
    });
  });
}
