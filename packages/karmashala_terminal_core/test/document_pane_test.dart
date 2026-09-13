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

  group('the documents that were already there', () {
    test('settings still answers as before', () {
      expect(isSettingsPane(kSettingsPaneId), isTrue);
      expect(isDocumentPane(kSettingsPaneId), isTrue);
      expect(isSettingsPane('shell:1'), isFalse);
      expect(isDocumentPane('shell:1'), isFalse);
    });
  });
}
