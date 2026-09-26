import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_checkpoints/checkpoints.dart';
import 'package:test/test.dart';

/// Turn edges off one session's status moves: the whole table.
void main() {
  late TurnBoundaryTracker turns;
  setUp(() => turns = TurnBoundaryTracker());

  test('working starts a turn once; idle and failed end it once', () {
    expect(turns.observe('s1', AgentActivityStatus.working), TurnEdge.started);
    expect(turns.inTurn('s1'), isTrue);
    expect(turns.observe('s1', AgentActivityStatus.working), isNull);
    expect(turns.observe('s1', AgentActivityStatus.idle), TurnEdge.ended);
    expect(turns.observe('s1', AgentActivityStatus.idle), isNull);
    expect(turns.observe('s1', AgentActivityStatus.working), TurnEdge.started);
    expect(turns.observe('s1', AgentActivityStatus.failed), TurnEdge.ended);
    expect(turns.inTurn('s1'), isFalse);
  });

  test('an approval or an unknown reading moves nothing', () {
    expect(turns.observe('s1', AgentActivityStatus.awaitingApproval), isNull);
    expect(turns.observe('s1', AgentActivityStatus.unknown), isNull);
    turns.observe('s1', AgentActivityStatus.working);
    expect(turns.observe('s1', AgentActivityStatus.awaitingApproval), isNull);
    expect(turns.observe('s1', AgentActivityStatus.unknown), isNull);
    expect(turns.inTurn('s1'), isTrue, reason: 'still the same turn');
  });

  test('an end with no start is no edge, and sessions are apart', () {
    expect(turns.observe('s1', AgentActivityStatus.idle), isNull);
    turns.observe('s1', AgentActivityStatus.working);
    expect(turns.inTurn('s2'), isFalse);
    turns.forget('s1');
    expect(turns.inTurn('s1'), isFalse);
  });
}
