import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';

/// Which modifier the app's own commands sit on.
///
/// Every chord was written `Ctrl+…`, so on a Mac the command panel was Ctrl+K
/// beside a menu bar where everything else is ⌘ — the same shape of bug as the
/// Cmd+Q that did nothing. Not all of them move, though, and that is the part
/// worth pinning: tab cycling is Ctrl+Tab on macOS too, and inside a terminal
/// Ctrl+C is SIGINT and Ctrl+V is readline's quoted-insert.
void main() {
  ShellChord chordFor(String label) =>
      shellChords.firstWhere((c) => c.label == label);

  bool has(String label) => shellChords.any((c) => c.label == label);

  group('on macOS', () {
    setUp(() => commandKeyIsMeta = true);
    tearDown(() => commandKeyIsMeta = false);

    test('the command panel is ⌘K, not Ctrl+K', () {
      final chord = chordFor('⌘K');
      expect(chord.activator.meta, isTrue);
      expect(chord.activator.control, isFalse);
      expect(has('Ctrl+K'), isFalse);
    });

    test('every app command moves to ⌘, including the shifted ones', () {
      for (final label in ['⌘1', '⌘B', '⇧⌘B', '⌘T', '⌘W', '⇧⌘P', '⌘=', '⌘0']) {
        final chord = chordFor(label);
        expect(chord.activator.meta, isTrue, reason: label);
        expect(chord.activator.control, isFalse, reason: label);
      }
    });

    test('tab cycling stays on Ctrl, because it is Ctrl on a Mac too', () {
      for (final label in ['Ctrl+Tab', 'Ctrl+Shift+Tab', 'Ctrl+PageDown']) {
        final chord = chordFor(label);
        expect(chord.activator.control, isTrue, reason: label);
        expect(chord.activator.meta, isFalse, reason: label);
      }
    });

    test('terminal copy and paste change shape, not just modifier', () {
      // ⌘C, not ⇧⌘C: a Mac terminal has no reason for the shift, because
      // Ctrl+C is not copy there in the first place.
      final copy = chordFor('⌘C');
      expect(copy.activator.meta, isTrue);
      expect(copy.activator.shift, isFalse);
      expect(chordFor('⌘V').activator.shift, isFalse);
    });

    test('plain Ctrl+V is not claimed — it is quoted-insert', () {
      expect(
        has('Ctrl+V'),
        isFalse,
        reason: '⌘V already pastes, so taking Ctrl+V would cost a shell '
            'binding for nothing',
      );
    });
  });

  group('on Windows and Linux', () {
    setUp(() => commandKeyIsMeta = false);

    test('nothing moved: the command panel is still Ctrl+K', () {
      final chord = chordFor('Ctrl+K');
      expect(chord.activator.control, isTrue);
      expect(chord.activator.meta, isFalse);
    });

    test('copy keeps the shift it needs, and Ctrl+V still pastes', () {
      final copy = chordFor('Ctrl+Shift+C');
      expect(copy.activator.control, isTrue);
      expect(copy.activator.shift, isTrue, reason: 'Ctrl+C is SIGINT');
      expect(has('Ctrl+V'), isTrue);
    });
  });

  test('the map follows the platform the chords were built for', () {
    // The map is cached on the platform flag, so the risk is a stale table:
    // chords rebuilt for macOS while the map still holds the Ctrl bindings.
    commandKeyIsMeta = true;
    addTearDown(() => commandKeyIsMeta = false);

    expect(shellShortcutMap.containsKey(chordFor('⌘K').activator), isTrue);
    expect(
      shellShortcutMap.containsKey(
        const SingleActivator(LogicalKeyboardKey.keyK, control: true),
      ),
      isFalse,
    );
  });
}
