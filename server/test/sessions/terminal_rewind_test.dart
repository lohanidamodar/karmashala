import 'package:agent_cli/descriptors.dart' show claudeConversationRewind;
import 'package:karmashala_host/src/sessions/rewind/terminal_rewind.dart';
import 'package:test/test.dart';

/// Claude Code 2.1.287's `/rewind`, as a ConPTY showed it on 2026-10-08:
/// the list oldest first with "(current)" selected, Up to go back, a
/// confirmation quoting the message with numbered choices, and the message
/// put back in the input once restored.
class _Claude {
  _Claude(this.messages, {this.opens = true});

  final List<String> messages;
  final bool opens;
  final pressed = <String>[];
  var state = 'prompt';
  var input = '';
  late int selected;

  List<String> screen() => switch (state) {
    'list' => [
      '  Rewind',
      '  Restore the code and/or conversation to the point before…',
      for (var i = 0; i < messages.length; i++) ...[
        '  ${i == selected ? '❯' : ' '} ${messages[i]}',
        '    ⚠ No code restore',
      ],
      '  ${selected == messages.length ? '❯' : ' '} (current)',
      '  Enter to continue · Esc to cancel',
    ],
    'confirm' => [
      '  Rewind',
      '  Confirm you want to restore the conversation to the point before '
          'you sent this message:',
      '  │ ${messages[selected]}',
      '  │ (22m ago)',
      '  The conversation will be forked.',
      '  ❯ 1. Restore conversation',
      '    2. Summarize from here',
      '    3. Summarize up to here',
      '    4. Never mind',
    ],
    _ => ['────', '❯ $input', '────'],
  };

  bool press(String keys) {
    pressed.add(keys);
    switch (state) {
      case 'prompt':
        if (keys == '\r' && input == '/rewind' && opens) {
          state = 'list';
          selected = messages.length;
          input = '';
        } else if (keys.contains('\x15')) {
          input = '';
        } else if (keys != '\x1b') {
          input += keys;
        }
      case 'list':
        if (keys == '\x1b') state = 'prompt';
        if (keys.startsWith('\x1b[A')) {
          selected -= '\x1b[A'.allMatches(keys).length;
        }
        if (keys == '\r') state = 'confirm';
      case 'confirm':
        if (keys == '\x1b') state = 'prompt';
        if (keys == '1') {
          state = 'prompt';
          input = messages[selected];
          messages.removeRange(selected, messages.length);
        }
    }
    return true;
  }
}

void main() {
  final menu = claudeConversationRewind.menu;

  ScreenTerminalRewind driver(_Claude claude) => ScreenTerminalRewind(
    screen: (_) => claude.screen(),
    press: (_, keys) => claude.press(keys),
    poll: const Duration(milliseconds: 1),
    patience: const Duration(milliseconds: 50),
  );

  test('types the command, goes back to the message, checks its quote, '
      'restores the conversation and clears the input', () async {
    final claude = _Claude(['one', 'two', 'three']);
    await driver(claude).rewind('s1', back: 1, menu: menu, words: 'two');
    expect(claude.pressed, [
      '/rewind',
      '\r',
      '\x1b[A\x1b[A',
      '\r',
      '1',
      '\x15',
    ]);
    expect(claude.messages, ['one']);
    expect(claude.input, isEmpty);
    expect(claude.state, 'prompt');
  });

  test('a quote that is not the message closes the menu and says to open '
      'the terminal, with nothing chosen', () async {
    final claude = _Claude(['one', 'two', 'three']);
    await expectLater(
      driver(claude).rewind('s1', back: 0, menu: menu, words: 'two'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'why',
          allOf(contains('not this one'), contains('Open the terminal')),
        ),
      ),
    );
    expect(claude.pressed, isNot(contains('1')));
    expect(claude.pressed.last, '\x1b');
    expect(claude.state, 'prompt');
    expect(claude.messages, hasLength(3));
  });

  test('a menu that never opens fails in words', () async {
    final claude = _Claude(['one'], opens: false);
    await expectLater(
      driver(claude).rewind('s1', back: 0, menu: menu, words: 'one'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'why',
          contains('message list'),
        ),
      ),
    );
  });
}
