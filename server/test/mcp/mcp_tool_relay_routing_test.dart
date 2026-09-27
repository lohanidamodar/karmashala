import 'package:karmashala_host/src/mcp/mcp_tool_relay.dart';
import 'package:karmashala_host/src/mcp/tools/server_tool_set.dart';
import 'package:karmashala_host/src/mcp/tools/server_tools.dart';
import 'package:test/test.dart';

/// One server tool: answered here, whatever app is or is not connected.
class _Here extends ServerToolSet {
  @override
  List<Map<String, Object?>> get schemas => const [
    {
      'name': 'here',
      'inputSchema': {'type': 'object', 'properties': {}},
    },
  ];

  @override
  Future<Object?>? call(
    String tool,
    Map<String, dynamic> arguments,
    String? callerSessionId,
  ) => tool == 'here' ? Future.value('answered here') : null;
}

/// Found live on 2976ec4c: the desktop app killed and reopened, and every
/// tool the server forwarded hung until the caller timed out. Since slice 5b
/// (protocol 28) nothing agent-facing is forwarded to an app at all: every
/// tool is the server's, and one that wants a window asks through a
/// `ClientIntent` (server/test/data/client_intents_test.dart).
void main() {
  test('a server tool is answered here, with no app anywhere', () async {
    final relay = McpToolRelay(tools: ServerTools([_Here()]));
    expect(await relay.call('here', const {}, null), 'answered here');
  });

  test('the catalogue is the server\'s tools and nothing else', () {
    final relay = McpToolRelay(tools: ServerTools([_Here()]));
    expect([for (final tool in relay.catalogue()) tool['name']], ['here']);
  });

  test('a tool the server does not serve answers at once, in words — there '
      'is no app to wait for', () async {
    final relay = McpToolRelay(tools: ServerTools([_Here()]));
    final watch = Stopwatch()..start();
    await expectLater(
      relay.call('inbox_gone', const {}, null),
      throwsA(
        isA<McpToolRelayFailure>().having(
          (e) => e.message,
          'message',
          'no tool is called inbox_gone',
        ),
      ),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });
}
