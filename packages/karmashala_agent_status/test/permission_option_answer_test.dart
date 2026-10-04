import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';
import 'package:test/test.dart';

/// An agent's own permission options cross the wire on its ask, and an
/// approval that names one of them crosses back naming it.
void main() {
  Object? wire(Object? json) => jsonDecode(jsonEncode(json));

  test('an ask carries the options its agent offered, in order', () {
    final ask = AgentToolAsk(
      toolName: 'Edit main.dart',
      input: const {},
      at: DateTime.utc(2026, 10, 4),
      toolUseId: 'c1',
      options: const [
        AgentToolAskOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
        AgentToolAskOption(
          id: 'allow-always',
          name: 'Always allow',
          kind: 'allow_always',
        ),
        AgentToolAskOption(
          id: 'reject-always',
          name: 'Never',
          kind: 'reject_always',
        ),
      ],
    );
    final read = AgentToolAsk.fromJson(wire(ask.toJson()))!;
    expect(read.options, ask.options);
    expect(read.options[1].allows && read.options[1].always, isTrue);
    expect(read.options[2].allows, isFalse);
    expect(read.options[2].always, isTrue);
  });

  test('an ask with no options leaves them off the wire', () {
    final ask = AgentToolAsk(
      toolName: 'Bash',
      input: const {},
      at: DateTime.utc(2026, 10, 4),
    );
    expect(ask.toJson().containsKey('options'), isFalse);
    expect(AgentToolAsk.fromJson(wire(ask.toJson()))!.options, isEmpty);
  });

  test('an approval names the option chosen, and keeps it without its ask',
      () {
    const request = ApprovalAnswerRequest(
      sessionId: 's1',
      approve: true,
      optionId: 'allow-always',
      ask: PromptAsk(toolUseId: 'c1'),
    );
    final read =
        PromptAnswerRequest.fromJson(wire(request.toJson()))!
            as ApprovalAnswerRequest;
    expect(read.optionId, 'allow-always');
    expect(read.withoutAsk().optionId, 'allow-always');
    const plain = ApprovalAnswerRequest(sessionId: 's1', approve: false);
    expect(plain.toJson().containsKey('optionId'), isFalse);
  });
}
