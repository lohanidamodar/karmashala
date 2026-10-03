import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/application/session_subagents_providers.dart';
import 'package:karmashala_data_protocol/karmashala_data_protocol.dart';

/// The panel asks again on a timer only while something is still moving:
/// every ask re-reads records and counts tokens on the server.
void main() {
  SessionSubagentList listOf(List<SubagentState> states) => SessionSubagentList(
    sessionId: 's1',
    entries: [
      for (final (i, state) in states.indexed)
        SessionSubagent(
          kind: SubagentKind.subagent,
          id: 't$i',
          title: 'job $i',
          state: state,
        ),
    ],
  );

  test('a running or blocked entry keeps the timer', () {
    expect(
      subagentsRefreshAfter(
        listOf([SubagentState.done, SubagentState.running]),
      ),
      kSubagentsRefresh,
    );
    expect(
      subagentsRefreshAfter(listOf([SubagentState.blocked])),
      kSubagentsRefresh,
    );
  });

  test('nothing live, or nothing at all, stops it', () {
    expect(
      subagentsRefreshAfter(
        listOf([
          SubagentState.done,
          SubagentState.failed,
          SubagentState.unknown,
        ]),
      ),
      isNull,
    );
    expect(subagentsRefreshAfter(listOf(const [])), isNull);
  });
}
