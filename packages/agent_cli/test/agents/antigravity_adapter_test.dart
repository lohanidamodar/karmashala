import 'dart:convert';

import 'package:agent_cli/src/agents/antigravity/antigravity_chat_protocol.dart';
import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/src/sessions/session_event_types.dart';
import 'package:test/test.dart';

void main() {
  group('parseAntigravityMessage', () {
    test('parses stream-json init event with conversation_id', () {
      final line = jsonEncode({
        'event': 'init',
        'conversation_id': 'df3c0708-a27f-4799-b761-57a657a84274',
        'init': {'cwd': '/workspace', 'tools': []},
      });

      final events = parseAntigravityMessage(line);
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.agentStatus);
      expect(events.first.data['state'], 'started');
      expect(
        events.first.data['sessionId'],
        'df3c0708-a27f-4799-b761-57a657a84274',
      );
    });

    test('parses stream-json step_update with text_delta', () {
      final line = jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_type': 'agent_response',
          'step_index': 1,
          'text_delta': 'Hello from Antigravity!',
        },
      });

      final events = parseAntigravityMessage(line);
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.agentMessage);
      expect(events.first.data['text'], 'Hello from Antigravity!');
    });

    test('parses stream-json step_update with tool call', () {
      final line = jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_type': 'tool',
          'state': 'ACTIVE',
          'step_index': 2,
          'tool_name': 'run_command',
          'tool_info': {
            'parameters': {'command': 'ls -la'},
          },
        },
      });

      final events = parseAntigravityMessage(line);
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.toolCall);
      expect(events.first.data['name'], 'run_command');
      expect(events.first.data['id'], '2');
      expect(events.first.data['input'], {'command': 'ls -la'});
    });

    test('parses stream-json result event with success', () {
      final line = jsonEncode({
        'event': 'result',
        'result': {
          'status': 'SUCCESS',
          'conversation_id': 'df3c0708-a27f-4799-b761-57a657a84274',
        },
      });

      final events = parseAntigravityMessage(line);
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.agentStatus);
      expect(events.first.data['state'], 'complete');
      expect(
        events.first.data['sessionId'],
        'df3c0708-a27f-4799-b761-57a657a84274',
      );
    });

    test('parses stream-json result event with error', () {
      final line = jsonEncode({
        'event': 'result',
        'result': {'status': 'ERROR', 'error': 'Quota exceeded'},
      });

      final events = parseAntigravityMessage(line);
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.error);
      expect(events.first.data['message'], 'Quota exceeded');
    });

    test('parses legacy json format', () {
      final msgLine = jsonEncode({'type': 'message', 'text': 'legacy message'});
      final errLine = jsonEncode({
        'type': 'error',
        'message': 'something failed',
      });

      expect(
        parseAntigravityMessage(msgLine).single.type,
        SessionEventTypes.agentMessage,
      );
      expect(
        parseAntigravityMessage(errLine).single.type,
        SessionEventTypes.error,
      );
    });

    test('treats plain text as agent message', () {
      final events = parseAntigravityMessage('Just some standard output line');
      expect(events, hasLength(1));
      expect(events.first.type, SessionEventTypes.agentMessage);
      expect(events.first.data['text'], 'Just some standard output line');
    });

    test('ignores empty or whitespace lines', () {
      expect(parseAntigravityMessage(''), isEmpty);
      expect(parseAntigravityMessage('   \t\n'), isEmpty);
    });
  });

  group('encodeAntigravityUserMessage', () {
    test(
      'passes plain text through, because the pane runs agy in TUI mode',
      () {
        expect(encodeAntigravityUserMessage('Hello agy'), 'Hello agy');
      },
    );

    test('does not wrap an already-encoded event either', () {
      const input = '{"event":"user","message":{"content":"hi"}}';
      expect(encodeAntigravityUserMessage(input), input);
    });
  });

  group('AntigravityAdapter.oneShot', () {
    test('constructs arguments with --print and stream-json output format', () {
      final invocation = const AntigravityAdapter().oneShot(
        'Summarize this repo',
      );

      expect(invocation.arguments, [
        '--print',
        'Summarize this repo',
        '--output-format',
        'stream-json',
      ]);
    });

    test('includes system prompt prepended to prompt', () {
      final invocation = const AntigravityAdapter().oneShot(
        'What is 2+2?',
        systemPrompt: 'Be concise.',
      );

      expect(invocation.arguments, [
        '--print',
        'Be concise.\n\nWhat is 2+2?',
        '--output-format',
        'stream-json',
      ]);
    });

    test('includes --model when specified', () {
      final invocation = const AntigravityAdapter().oneShot(
        'Analyze code',
        model: 'gemini-3.8-flash-high',
      );

      expect(invocation.arguments, [
        '--print',
        'Analyze code',
        '--output-format',
        'stream-json',
        '--model',
        'gemini-3.8-flash-high',
      ]);
    });

    test('parses assistant text from stream-json output line', () {
      final invocation = const AntigravityAdapter().oneShot('Hello');

      final line = jsonEncode({
        'event': 'step_update',
        'step_update': {
          'step_type': 'agent_response',
          'text_delta': '42 is the answer',
        },
      });

      expect(invocation.parse(line), '42 is the answer');
    });
  });
}
