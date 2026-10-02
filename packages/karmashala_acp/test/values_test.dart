import 'package:karmashala_acp/karmashala_acp.dart';
import 'package:test/test.dart';

void main() {
  group('vocabulary', () {
    test('every typed enum names exactly the strings the vocabulary lists', () {
      List<String> raws(List<WireEnum> values) => [
        for (final v in values) v.raw,
      ];
      expect(raws(StopReason.known), AcpVocabulary.stopReasons);
      expect(raws(ToolKind.known), AcpVocabulary.toolKinds);
      expect(raws(ToolCallStatus.known), AcpVocabulary.toolCallStatuses);
      expect(
        raws(PermissionOptionKind.known),
        AcpVocabulary.permissionOptionKinds,
      );
      expect(raws(PlanEntryPriority.known), AcpVocabulary.planEntryPriorities);
      expect(raws(PlanEntryStatus.known), AcpVocabulary.planEntryStatuses);
    });

    test('every modelled SessionUpdate kind is in the vocabulary and parses '
        'back to its own class', () {
      const samples = <SessionUpdate>[
        UserMessageChunk(TextContent('u')),
        AgentMessageChunk(TextContent('a')),
        AgentThoughtChunk(TextContent('t')),
        ToolCallUpdate(toolCallId: 'c', isNew: true),
        ToolCallUpdate(toolCallId: 'c'),
        PlanUpdate([]),
        AvailableCommandsUpdate([]),
        CurrentModeUpdate('m'),
        ConfigOptionUpdate([]),
        SessionInfoUpdate(),
        UsageUpdate(used: 1, size: 2),
      ];
      expect([
        for (final s in samples) s.sessionUpdate,
      ], AcpVocabulary.sessionUpdates);
      for (final sample in samples) {
        final back = SessionUpdate.fromJson(sample.toJson());
        expect(
          back.runtimeType,
          sample.runtimeType,
          reason: sample.toJson().toString(),
        );
        expect(back.toJson(), sample.toJson());
      }
    });
  });

  group('lenient parsing', () {
    test('unknown fields are ignored and an unknown enum string is kept as '
        'unknown(raw) through a round trip', () {
      final update = SessionUpdate.fromJson({
        'sessionUpdate': 'tool_call',
        'toolCallId': 'c1',
        'title': 'Run tests',
        'kind': 'telepathy',
        'status': 'queued',
        'futureField': {'nested': true},
        'locations': [
          {'path': 'a.dart', 'line': 3, 'column': 9},
        ],
      });
      final call = update as ToolCallUpdate;
      expect(call.isNew, isTrue);
      expect(call.kind, const ToolKind.unknown('telepathy'));
      expect(call.kind!.isKnown, isFalse);
      expect(call.status!.raw, 'queued');
      expect(call.locations, [const ToolCallLocation('a.dart', line: 3)]);
      expect(call.toJson()['kind'], 'telepathy');
      expect(StopReason.fromJson('end_turn'), StopReason.endTurn);
      expect(StopReason.fromJson('end_turn').isKnown, isTrue);
      expect(StopReason.fromJson('paused'), isNot(StopReason.endTurn));
      expect(StopReason.fromJson('paused').toJson(), 'paused');
    });

    test('an unknown sessionUpdate variant becomes UnknownUpdate and goes '
        'back out unchanged', () {
      final raw = {
        'sessionUpdate': 'mood_update',
        'mood': 'cheerful',
        'content': {'type': 'text', 'text': 'ignored'},
      };
      final update = SessionUpdate.fromJson(raw);
      expect(update, isA<UnknownUpdate>());
      expect((update as UnknownUpdate).kind, 'mood_update');
      expect(update.toJson(), raw);
    });

    test('content blocks: every type round-trips; an unknown one is kept', () {
      final blocks = [
        {'type': 'text', 'text': 'hi'},
        {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
        {'type': 'audio', 'data': 'BBBB', 'mimeType': 'audio/wav'},
        {'type': 'resource_link', 'uri': 'file:///a', 'name': 'a', 'size': 3},
        {
          'type': 'resource',
          'resource': {
            'uri': 'file:///b',
            'mimeType': 'text/plain',
            'text': 'b',
          },
        },
        {'type': 'video', 'uri': 'file:///c'},
      ];
      final parsed = [for (final b in blocks) ContentBlock.fromJson(b)];
      expect(parsed.map((b) => b.runtimeType), [
        TextContent,
        ImageContent,
        AudioContent,
        ResourceLinkContent,
        EmbeddedResourceContent,
        UnknownContent,
      ]);
      expect([for (final b in parsed) b.toJson()], blocks);
    });

    test('a missing required field in a result throws FormatException, a '
        'missing optional one reads as null', () {
      expect(
        () => NewSessionResult.fromJson({'modes': null}),
        throwsFormatException,
      );
      final result = NewSessionResult.fromJson({
        'sessionId': 's1',
        'modes': {
          'currentModeId': 'ask',
          'availableModes': [
            {'id': 'ask', 'name': 'Ask'},
            'not an object',
            {'id': 'code', 'name': 'Code', 'description': 'edits files'},
          ],
        },
      });
      expect(result.configOptions, isNull);
      expect(result.modes!.currentModeId, 'ask');
      expect(result.modes!.availableModes.map((m) => m.id), ['ask', 'code']);
    });

    test(
      'config options: ungrouped and grouped selects flatten to choices',
      () {
        final options = configOptionsFromJson([
          {
            'id': 'model',
            'name': 'Model',
            'type': 'select',
            'category': 'model',
            'currentValue': 'fast',
            'options': [
              {'value': 'fast', 'name': 'Fast'},
              {
                'name': 'Large',
                'options': [
                  {'value': 'big', 'name': 'Big'},
                ],
              },
            ],
          },
          {
            'id': 'think',
            'name': 'Think',
            'type': 'boolean',
            'currentValue': true,
          },
        ])!;
        expect(options[0].isSelect, isTrue);
        expect(options[0].options.map((o) => o.value), ['fast', 'big']);
        expect(options[0].options[1].group, 'Large');
        expect(options[1].isBoolean, isTrue);
        expect(options[1].currentValue, true);
      },
    );

    test('McpServerEntry writes env and headers as name/value pairs', () {
      expect(
        const McpServerEntry.stdio(
          'k',
          command: 'node',
          args: ['srv.js'],
          env: {'A': '1'},
        ).toJson(),
        {
          'name': 'k',
          'command': 'node',
          'args': ['srv.js'],
          'env': [
            {'name': 'A', 'value': '1'},
          ],
        },
      );
      expect(
        const McpServerEntry.http(
          'k',
          url: 'http://127.0.0.1:1/mcp',
          headers: {'Authorization': 'Bearer t'},
        ).toJson(),
        {
          'type': 'http',
          'name': 'k',
          'url': 'http://127.0.0.1:1/mcp',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer t'},
          ],
        },
      );
    });

    test('ToolCallUpdate.merge lays present fields over a call', () {
      const opened = ToolCallUpdate(
        toolCallId: 'c',
        isNew: true,
        title: 'Edit',
        kind: ToolKind.edit,
        status: ToolCallStatus.pending,
      );
      final merged = opened.merge(
        const ToolCallUpdate(toolCallId: 'c', status: ToolCallStatus.completed),
      );
      expect(merged.title, 'Edit');
      expect(merged.kind, ToolKind.edit);
      expect(merged.status, ToolCallStatus.completed);
      expect(merged.isNew, isTrue);
    });
  });
}
