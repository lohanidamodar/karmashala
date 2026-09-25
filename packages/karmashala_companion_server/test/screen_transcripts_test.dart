import 'package:karmashala_companion_server/karmashala_companion_server.dart';
import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 9, 25, 12);
  late ScreenTranscripts transcripts;

  setUp(() {
    now = DateTime.utc(2026, 9, 25, 12);
    transcripts = ScreenTranscripts(
      minInterval: const Duration(seconds: 5),
      maxScreens: 3,
      clock: () => now,
    );
  });

  test('each distinct screen is one more message, so the wire appends', () {
    expect(transcripts.read('s', 'one').cursor, 1);
    now = now.add(const Duration(seconds: 6));
    final page = transcripts.read('s', 'two');

    expect(page.cursor, 2);
    expect([for (final m in page.messages) m.text], ['one', 'two']);
  });

  test('an unchanged screen adds nothing', () {
    transcripts.read('s', 'same');
    now = now.add(const Duration(seconds: 6));
    expect(transcripts.read('s', 'same  ').cursor, 1);
  });

  test('a spinner is kept at most once per interval', () {
    transcripts.read('s', 'frame 1');
    now = now.add(const Duration(seconds: 1));
    expect(transcripts.read('s', 'frame 2').cursor, 1);
    now = now.add(const Duration(seconds: 5));
    expect(transcripts.read('s', 'frame 3').cursor, 2);
  });

  test('a history past its bound starts again from now', () {
    for (var i = 0; i < 3; i++) {
      transcripts.read('s', 'screen $i');
      now = now.add(const Duration(seconds: 6));
    }
    final page = transcripts.read('s', 'screen 3');

    expect([for (final m in page.messages) m.text], ['screen 3']);
  });

  test('no screen is said, never drawn as an empty chat', () {
    final page = transcripts.read('s', null);

    expect(page.messages, isEmpty);
    expect(page.absence, RemoteTranscriptAbsence.noChatView);
  });
}
