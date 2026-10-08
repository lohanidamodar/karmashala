import 'package:karmashala_host/src/sessions/rewind/rewind_cuts.dart';
import 'package:test/test.dart';

void main() {
  test('a cut is kept across a restart until it is taken', () {
    String? stored;
    RewindCuts open() =>
        RewindCuts(read: () => stored, write: (value) => stored = value);
    open().cut('s1', 'entry-3');
    final again = open();
    expect(again.cutOf('s1'), 'entry-3');
    expect(again.cutOf('s2'), isNull);
    again.taken('s1');
    expect(open().cutOf('s1'), isNull);
  });

  test('an unreadable record holds no cut', () {
    expect(RewindCuts(read: () => 'not json').cutOf('s1'), isNull);
  });
}
