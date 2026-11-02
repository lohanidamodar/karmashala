import 'package:karmashala_host/src/bot/bot_approval_summary.dart';
import 'package:karmashala_mcp/catalogue.dart';
import 'package:test/test.dart';

/// What a person says Yes to. They read this and nothing else unless they ask
/// for the call, so it is a sentence, with names where they can be looked up.
void main() {
  final names = BotCallNames(
    session: (id) => id == 's1' ? 'Fix login' : null,
    terminal: (id) => id == 't1' ? 'PowerShell' : null,
    checkout: (id) => id == 'r1' ? 'karmashala' : null,
  );

  String say(String tool, Map<String, dynamic> arguments) =>
      botApprovalSummary(tool, arguments, names: names);

  group('names what it can look up', () {
    test('a session by its title', () {
      expect(
        say('session_end', {'sessionId': 's1'}),
        "End session 'Fix login'",
      );
      expect(
        say('delegation_detach', {'sessionId': 's1'}),
        "Detach session 'Fix login' from the bot",
      );
      expect(
        say('session_rewind', {'sessionId': 's1', 'turnIndex': 3}),
        "Rewind session 'Fix login' to turn 3",
      );
      expect(
        say('session_answer', {'sessionId': 's1', 'decision': 'approve'}),
        "Answer session 'Fix login': approve",
      );
    });

    test('a terminal by its title, saying when it is forced', () {
      expect(
        say('terminal_close', {'tabId': 't1', 'kill': true}),
        "Force close the terminal 'PowerShell'",
      );
      expect(
        say('terminal_close', {'tabId': 't1'}),
        "Close the terminal 'PowerShell'",
      );
      expect(
        say('terminal_run', {'paneId': 't1', 'command': 'git status'}),
        "Run 'git status' in the terminal 'PowerShell'",
      );
    });

    test('a worktree by its checkout', () {
      expect(
        say('worktree_remove', {'repositoryId': 'r1'}),
        "Remove the worktree 'karmashala'",
      );
    });
  });

  test('what it cannot look up it says by id, in words', () {
    expect(say('session_end', {'sessionId': 'gone'}), 'End session gone');
    expect(
      say('terminal_close', {'tabId': 'gone', 'kill': true}),
      'Force close the terminal gone',
    );
  });

  test('a tool it has no sentence for still reads as words', () {
    expect(
      say('some_new_tool', {
        'target': 'x',
        'count': 2,
        'force': true,
        'nested': {'a': 1},
        'list': [1, 2],
      }),
      'Some new tool: target x, count 2, force true, and 2 more in the call',
    );
    expect(say('some_new_tool', const {}), 'Some new tool');
  });

  test('every destructive tool in the catalogue reads as a sentence', () {
    final destructive = [
      for (final MapEntry(key: tool, value: note)
          in kMcpToolAnnotations.entries)
        if (note.destructive == true) tool,
    ];
    expect(destructive, isNotEmpty);
    const arguments = <String, dynamic>{
      'sessionId': 's1',
      'tabId': 't1',
      'paneId': 't1',
      'repositoryId': 'r1',
      'id': 'an-id',
      'nested': {'a': 1},
    };
    for (final tool in destructive) {
      final words = say(tool, arguments);
      expect(words, isNot(contains('{')), reason: tool);
      expect(words, isNot(contains('}')), reason: tool);
      expect(words, isNot(contains('_')), reason: tool);
      expect(words[0], words[0].toUpperCase(), reason: tool);
    }
  });

  test('a long value is cut, so a card stays a card', () {
    final words = say('terminal_run', {'paneId': 't1', 'command': 'x' * 900});
    expect(words.length, lessThan(300));
  });
}
