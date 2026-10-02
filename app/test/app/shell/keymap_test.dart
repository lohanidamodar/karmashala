import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/app/shell/keymap.dart';
import 'package:karmashala/src/app/shell/keymap_controller.dart';
import 'package:karmashala/src/app/shell/shell_shortcuts.dart';

/// A keymap file over the app's own chords: what it may say, what it does to
/// the table every key runs on, and that a bad edit changes nothing.
void main() {
  final wasMeta = commandKeyIsMeta;
  setUp(() => commandKeyIsMeta = false);
  tearDown(() {
    applyKeymapEntries(const []);
    commandKeyIsMeta = wasMeta;
  });

  Set<String> commands() => keymapCommands(defaultShellChords);
  KeymapReading read(String text) => parseKeymap(text, commands: commands());

  group('keys', () {
    test('mod is Ctrl here and ⌘ on a Mac', () {
      expect(
        sameKeys(
          parseKeymapKeys('mod+shift+k'),
          const SingleActivator(
            LogicalKeyboardKey.keyK,
            control: true,
            shift: true,
          ),
        ),
        isTrue,
      );
      commandKeyIsMeta = true;
      expect(parseKeymapKeys('mod+k').meta, isTrue);
      expect(parseKeymapKeys('mod+k').control, isFalse);
    });

    test('are written the way the platform writes them', () {
      final keys = parseKeymapKeys('ctrl+alt+shift+pagedown');
      expect(keymapKeysLabel(keys), 'Ctrl+Alt+Shift+PageDown');
      commandKeyIsMeta = true;
      expect(keymapKeysLabel(parseKeymapKeys('cmd+shift+j')), '⇧⌘J');
      expect(keymapKeysLabel(parseKeymapKeys('ctrl+alt+up')), '⌃⌥Up');
    });

    test('a modifier or key it does not know is named', () {
      expect(
        () => parseKeymapKeys('hyper+k'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('"hyper"'),
          ),
        ),
      );
      expect(() => parseKeymapKeys('ctrl+'), throwsFormatException);
      expect(() => parseKeymapKeys('ctrl+nope'), throwsFormatException);
    });
  });

  group('a reading', () {
    test('an empty or missing file is the app’s own keys', () {
      expect(read('').entries, isEmpty);
      expect(read('').isUsable, isTrue);
    });

    test('each problem names its entry, and none is half applied', () {
      final reading = read('''[
        {"keys": "ctrl+alt+n", "command": "session.new"},
        {"keys": "ctrl+alt+x", "command": "no.such"},
        {"keys": "bogus+k", "command": "session.new"},
        {}
      ]''');
      expect(reading.isUsable, isFalse);
      expect(reading.problems, [
        contains('Entry 2: there is no command "no.such"'),
        contains('Entry 3'),
        contains('Entry 4 names neither'),
      ]);
    });

    test('broken JSON says so', () {
      expect(read('[{').problems.single, startsWith('Not valid JSON'));
      expect(read('{}').problems.single, contains('must be a list'));
    });
  });

  group('resolving', () {
    List<ShellChord> resolve(String text) =>
        resolveKeymap(defaultShellChords, read(text).entries).chords;

    test('a binding runs the command on new keys, and says it is ours', () {
      final chords = resolve(
        '[{"keys": "ctrl+alt+n", "command": "session.new"}]',
      );
      final added = chords.singleWhere(
        (c) => c.command == 'session.new' && c.fromKeymap,
      );
      expect(added.label, 'Ctrl+Alt+N');
      expect(added.intent, isA<NewSessionIntent>());
      expect(added.skipsShell, isTrue, reason: 'asked for, so a pane lets it');
      // The default stays unless its keys are taken.
      expect(chords.where((c) => c.label == 'Ctrl+N'), hasLength(1));
    });

    test('keys the file takes lose whatever held them', () {
      final chords = resolve(
        '[{"keys": "mod+n", "command": "terminal.newTab"}]',
      );
      final onKeys = chords.where((c) => c.label == 'Ctrl+N').single;
      expect(onKeys.command, 'terminal.newTab');
      expect(chords.where((c) => c.command == 'session.new'), isEmpty);
    });

    test('null unbinds a key, or a command from every key', () {
      final unboundKey = resolve('[{"keys": "mod+k", "command": null}]');
      expect(unboundKey.where((c) => c.label == 'Ctrl+K'), isEmpty);
      expect(
        unboundKey.where((c) => c.command == 'quickOpen.show'),
        isNotEmpty,
        reason: 'Ctrl+P still opens it',
      );

      final unboundCommand = resolve('[{"command": "quickOpen.show"}]');
      expect(
        unboundCommand.where((c) => c.command == 'quickOpen.show'),
        isEmpty,
      );
    });

    test('the tables every key reads follow it', () {
      applyKeymapEntries(
        read('[{"keys": "ctrl+alt+n", "command": "session.new"}]').entries,
      );
      expect(
        shellShortcutMap.entries.any(
          (e) =>
              e.value is NewSessionIntent &&
              sameKeys(e.key as SingleActivator, parseKeymapKeys('ctrl+alt+n')),
        ),
        isTrue,
      );
      expect(shellCommandLabel('session.new'), 'Ctrl+N');
    });
  });

  group('the file', () {
    late Directory dir;
    late ProviderContainer container;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('ks-keymap');
      container = ProviderContainer(
        overrides: [
          keymapFileProvider.overrideWith(
            (ref) async => File('${dir.path}/keymap.json'),
          ),
        ],
      );
    });
    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<KeymapStatus> settled() async {
      container.read(keymapProvider);
      await container.read(keymapFileProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return container.read(keymapProvider);
    }

    test(
      'a good edit is applied; a bad one keeps it and says why',
      tags: 'shared-runner',
      () async {
        File('${dir.path}/keymap.json').writeAsStringSync(
          '[{"keys": "ctrl+alt+n", "command": "session.new"}]',
        );
        final first = await settled();
        expect(first.problems, isEmpty);
        expect(first.entries, 1);
        expect(shellChords.any((c) => c.label == 'Ctrl+Alt+N'), isTrue);

        container.read(keymapProvider.notifier).apply('[{"keys": ');
        final bad = container.read(keymapProvider);
        expect(bad.problems, isNotEmpty);
        expect(bad.revision, first.revision, reason: 'nothing was applied');
        expect(shellChords.any((c) => c.label == 'Ctrl+Alt+N'), isTrue);
      },
    );

    test('a first edit starts from an example that changes nothing', () async {
      await settled();
      final file = await container.read(keymapProvider.notifier).ensureFile();
      expect(file!.readAsStringSync(), kKeymapTemplate);
      final reading = read(kKeymapTemplate);
      expect(reading.isUsable, isTrue);
      final before = defaultShellChords.map((c) => (c.label, c.command));
      final after = resolveKeymap(
        defaultShellChords,
        reading.entries,
      ).chords.map((c) => (c.label, c.command));
      expect(after.toSet(), before.toSet());
    });
  });
}
