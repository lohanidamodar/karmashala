import 'package:karmashala_terminal_core/geometry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A host path is spelled for Windows, so every awkward shape one can take
  // has to survive being a pane id: a drive colon, a UNC share, spaces.
  const paths = <String>[
    r'C:\src\app\lib\main.dart',
    r'\\wsl.localhost\archlinux\home\d\projects\app\lib\main.dart',
    r'D:\My Files\notes: draft\a b.md',
    '/home/d/projects/app/lib/main.dart',
  ];

  group('an editor pane id', () {
    test('round-trips every host path shape', () {
      for (final path in paths) {
        expect(editorPanePath(editorPaneId(path)), path, reason: path);
        expect(isEditorPane(editorPaneId(path)), isTrue, reason: path);
      }
    });

    test('is a document pane, so restore already carries it', () {
      for (final path in paths) {
        expect(isDocumentPane(editorPaneId(path)), isTrue, reason: path);
        expect(isSettingsPane(editorPaneId(path)), isFalse, reason: path);
      }
    });

    test('names no path when the id is not one', () {
      expect(editorPanePath(kSettingsPaneId), isNull);
      expect(editorPanePath('shell:1'), isNull);
      expect(editorPanePath(kEditorPanePrefix), isNull);
      expect(isEditorPane(kSettingsPaneId), isFalse);
      expect(isEditorPane('shell:1'), isFalse);
      expect(isEditorPane(kEditorPanePrefix), isFalse);
    });
  });

  group('a diff pane id', () {
    test('round-trips all three fields, whatever shape the paths take', () {
      for (final path in paths) {
        final id = diffPaneId(
          environmentId: 'wsl:archlinux',
          checkoutPath: r'C:\src\app',
          path: path,
        );
        expect(diffPaneTarget(id), (
          environmentId: 'wsl:archlinux',
          checkoutPath: r'C:\src\app',
          path: path,
        ), reason: path);
        expect(isDiffPane(id), isTrue, reason: path);
      }
    });

    test('is a document, and is not the editor\'s', () {
      final id = diffPaneId(
        environmentId: 'windows',
        checkoutPath: r'C:\src\app',
        path: 'lib/main.dart',
      );
      expect(isDocumentPane(id), isTrue);
      expect(isSettingsPane(id), isFalse);
      // An editor pane and a diff pane are different documents over one file.
      expect(isEditorPane(id), isFalse);
      expect(editorPanePath(id), isNull);
      expect(isDiffPane(editorPaneId(r'C:\src\app\lib\main.dart')), isFalse);
    });

    test('names nothing for an id that is not one', () {
      expect(diffPaneTarget(kSettingsPaneId), isNull);
      expect(diffPaneTarget('shell:1'), isNull);
      expect(diffPaneTarget(kDiffPanePrefix), isNull);
      expect(isDiffPane(kSettingsPaneId), isFalse);
    });

    test('names nothing for the wrong number of fields', () {
      const sep = kPaneFieldSeparator;
      expect(diffPaneTarget('${kDiffPanePrefix}windows${sep}C:\\app'), isNull);
      expect(
        diffPaneTarget('${kDiffPanePrefix}windows${sep}C:\\app${sep}a${sep}b'),
        isNull,
      );
    });

    test('names nothing when any one field is empty', () {
      const sep = kPaneFieldSeparator;
      // Half an answer would diff some other file rather than refuse.
      expect(
        diffPaneTarget('$kDiffPanePrefix${sep}C:\\app${sep}a.dart'),
        isNull,
      );
      expect(
        diffPaneTarget('${kDiffPanePrefix}windows$sep${sep}a.dart'),
        isNull,
      );
      expect(
        diffPaneTarget('${kDiffPanePrefix}windows${sep}C:\\app$sep'),
        isNull,
      );
    });
  });

  group('the documents that were already there', () {
    test('settings still answers as before', () {
      expect(isSettingsPane(kSettingsPaneId), isTrue);
      expect(isDocumentPane(kSettingsPaneId), isTrue);
      expect(isSettingsPane('shell:1'), isFalse);
      expect(isDocumentPane('shell:1'), isFalse);
    });
  });
  group('a note pane id', () {
    test('round-trips the note id and is a document pane', () {
      const id = 'note-1700000000000000-3';
      expect(notePaneNoteId(notePaneId(id)), id);
      expect(isNotePane(notePaneId(id)), isTrue);
      expect(isDocumentPane(notePaneId(id)), isTrue);
      expect(isEditorPane(notePaneId(id)), isFalse);
    });

    test('names no note when the id is not one', () {
      expect(notePaneNoteId(kSettingsPaneId), isNull);
      expect(notePaneNoteId(kNotePanePrefix), isNull);
      expect(isNotePane(editorPaneId('/a/b.md')), isFalse);
    });
  });
}
