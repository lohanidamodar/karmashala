import 'package:agent_cli/descriptors.dart';
import 'package:test/test.dart';
import 'package:karmashala_agent_status/karmashala_agent_status.dart';

/// A pane showing Claude Code's folder-trust menu, which moves its highlight on
/// the arrow keys and records what Enter confirmed — the behaviour measured in
/// `live_prompt_probe_test.dart`.
class FakeMenuPane {
  FakeMenuPane(this.options, {this.highlighted = 0});

  final List<String> options;
  int highlighted;
  final List<String> pressed = [];
  String? confirmed;

  /// When false, arrows do nothing: an agent that does not move as measured.
  bool moves = true;

  /// Swapped in to stand for another prompt replacing this one.
  List<String>? replacement;

  List<String> get screen =>
      replacement ??
      [
        ' Security guide',
        '',
        for (var i = 0; i < options.length; i++)
          i == highlighted ? ' ❯ ${options[i]}' : '   ${options[i]}',
        '',
        ' Enter to confirm · Esc to cancel',
      ];

  bool press(String keys) {
    pressed.add(keys);
    for (final m in RegExp(r'\x1b\[[AB]|\r').allMatches(keys)) {
      switch (m[0]) {
        case '\x1b[B' when moves:
          highlighted = (highlighted + 1).clamp(0, options.length - 1);
        case '\x1b[A' when moves:
          highlighted = (highlighted - 1).clamp(0, options.length - 1);
        case '\r':
          confirmed = options[highlighted];
      }
    }
    return true;
  }
}

void main() {
  const trust = ['No, exit', 'Yes, I trust this folder'];

  SessionMenuAnswerer answererFor(FakeMenuPane pane, {bool asking = true}) =>
      SessionMenuAnswerer(
        readScreen: (_) => pane.screen,
        supportFor: (_) => const AgentMenuSupport(markers: ['❯']),
        isAsking: (_) => asking,
        press: (_, keys) => pane.press(keys),
        poll: const Duration(milliseconds: 1),
        patience: const Duration(milliseconds: 50),
      );

  test('choosing the second option moves there first, then confirms', () async {
    final pane = FakeMenuPane(trust);
    final answerer = answererFor(pane);
    final menu = answerer.read('s1')!;

    final chosen = await answerer.choose('s1', menuId: menu.id, option: 1);

    expect(chosen, 'Yes, I trust this folder');
    expect(pane.confirmed, 'Yes, I trust this folder');
    expect(pane.pressed, [
      '\x1b[B',
      '\r',
    ], reason: 'the move, then Enter alone');
  });

  test('choosing what is highlighted is Enter alone', () async {
    final pane = FakeMenuPane(trust);
    final answerer = answererFor(pane);

    await answerer.choose('s1', menuId: answerer.read('s1')!.id, option: 0);

    expect(pane.pressed, ['\r']);
  });

  test('a highlight that does not move is never confirmed', () async {
    final pane = FakeMenuPane(trust)..moves = false;
    final answerer = answererFor(pane);

    await expectLater(
      answerer.choose('s1', menuId: answerer.read('s1')!.id, option: 1),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(
      pane.confirmed,
      isNull,
      reason: 'Enter would have chosen "No, exit"',
    );
  });

  test('an answer for a menu that has since changed chooses nothing', () async {
    final pane = FakeMenuPane(trust);
    final answerer = answererFor(pane);
    final shown = answerer.read('s1')!;
    pane.replacement = [' Do you want to proceed?', ' ❯ 1. Yes', '   2. No'];

    await expectLater(
      answerer.choose('s1', menuId: shown.id, option: 1),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(pane.pressed, isEmpty);
  });

  test('no menu is read while the session is not asking', () {
    final pane = FakeMenuPane(trust);
    expect(answererFor(pane, asking: false).read('s1'), isNull);
  });

  test('an option out of range is refused', () async {
    final pane = FakeMenuPane(trust);
    final answerer = answererFor(pane);

    await expectLater(
      answerer.choose('s1', menuId: answerer.read('s1')!.id, option: 5),
      throwsA(isA<SessionPromptRefusal>()),
    );
    expect(pane.pressed, isEmpty);
  });
}
