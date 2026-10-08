import 'dart:convert';

import 'package:agent_cli/descriptors.dart';
import 'package:agent_cli/read.dart';
import 'package:test/test.dart';

String _line(Map<String, Object?> record) => jsonEncode(record);

Map<String, Object?> _user(
  String uuid,
  String? parent,
  Object content, {
  bool meta = false,
  bool sidechain = false,
}) => {
  'type': 'user',
  'uuid': uuid,
  'parentUuid': parent,
  'isMeta': ?(meta ? true : null),
  'isSidechain': sidechain,
  'message': {'role': 'user', 'content': content},
};

Map<String, Object?> _assistant(String uuid, String parent) => {
  'type': 'assistant',
  'uuid': uuid,
  'parentUuid': parent,
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': 'OK'},
    ],
  },
};

void main() {
  group('claudeConversationPrompts', () {
    final lines = [
      _line(_user('u1', null, 'Remember APPLE')),
      _line(_assistant('a1', 'u1')),
      _line({'type': 'system', 'uuid': 's1', 'parentUuid': 'a1'}),
      _line(
        _user('u2', 's1', [
          {'type': 'text', 'text': 'Remember BANANA'},
        ]),
      ),
      _line(
        _user('t2', 'u2', [
          {'type': 'tool_result', 'tool_use_id': 'x', 'content': 'done'},
        ]),
      ),
      _line(_user('m2', 't2', 'caveat', meta: true)),
      _line(_user('side', 'm2', 'a subagent prompt', sidechain: true)),
      _line(_assistant('a2', 'm2')),
      // A rewind's branch from a1: the newest leaf wins.
      _line(_user('u3', 'a1', 'Remember CHERRY')),
      _line(_assistant('a3', 'u3')),
      'not json',
    ];

    test('walks the newest chain and keeps only the person\'s prompts', () {
      final prompts = claudeConversationPrompts(lines);
      expect(prompts.map((p) => p.uuid), ['u1', 'u3']);
      expect(prompts.first.parentUuid, isNull);
      expect(prompts.last.parentUuid, 'a1');
      expect(prompts.last.text, 'Remember CHERRY');
    });

    test('follows the leaf it is given', () {
      final prompts = claudeConversationPrompts(lines, leaf: 'a2');
      expect(prompts.map((p) => p.text), ['Remember APPLE', 'Remember BANANA']);
      expect(prompts.last.parentUuid, 's1');
    });

    test('stops at a compaction summary', () {
      final compacted = [
        _line(_user('u1', null, 'old')),
        _line({..._user('c1', null, 'summary'), 'isCompactSummary': true}),
        _line(_user('u2', 'c1', 'new')),
      ];
      expect(claudeConversationPrompts(compacted).map((p) => p.text), ['new']);
    });

    test('Claude Code declares its cut and its menu', () {
      final rewind = claudeRewind.conversation!;
      expect(rewind.menu.command, '/rewind');
      expect(rewind.menu.labels.keys, RewindMode.values);
    });
  });

  group('rewoundRows', () {
    List<bool> fold(List<(String, String)> rows) => rewoundRows(
      rows.length,
      roleAt: (i) => rows[i].$1,
      textAt: (i) => rows[i].$2,
      opensTurn: (i) => rows[i].$1 == 'user',
    );

    const marker2 = RewindMarker(turns: 2, mode: RewindMode.both);
    const marker1 = RewindMarker(turns: 1, mode: RewindMode.conversation);

    test('the marker reads back what it wrote', () {
      expect(marker2.text, 'Rewound 2 turns · Code and conversation');
      final parsed = RewindMarker.parse(marker1.text)!;
      expect(parsed.turns, 1);
      expect(parsed.mode, RewindMode.conversation);
      expect(RewindMarker.parse('something else'), isNull);
    });

    test('folds the turns before a marker, not the marker', () {
      final rows = [
        ('user', 'one'),
        ('agent', 'a'),
        ('user', 'two'),
        ('tool', 't'),
        ('user', 'three'),
        ('agent', 'c'),
        (kTranscriptRewindRole, marker2.text),
        ('user', 'two again'),
      ];
      expect(fold(rows), [false, false, true, true, true, true, false, false]);
    });

    test('a later marker counts only turns no marker folded', () {
      final rows = [
        ('user', 'one'),
        ('user', 'two'),
        (kTranscriptRewindRole, marker1.text),
        ('user', 'two again'),
        ('user', 'three'),
        (kTranscriptRewindRole, marker2.text),
      ];
      expect(fold(rows), [false, true, false, true, true, false]);
    });
  });
}
