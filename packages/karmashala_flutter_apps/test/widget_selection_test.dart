import 'package:test/test.dart';
import 'package:karmashala_flutter_apps/flutter_apps.dart';

void main() {
  group('WidgetSelection.fromInspectorNode', () {
    // Captured 2026-09-08 from a real
    // `ext.flutter.inspector.getSelectedSummaryWidget` reply on Flutter 3.47.2.
    final real = <String, Object?>{
      'description': 'Text',
      'type': '_ElementDiagnosticableTreeNode',
      'valueId': 'inspector-7',
      'locationId': 7,
      'creationLocation': <String, Object?>{
        'file': 'file:///C:/kw/probeapp/lib/main.dart',
        'line': 107,
        'column': 19,
        'name': 'Text',
      },
      'createdByLocalProject': true,
      'widgetRuntimeType': 'Text',
      'stateful': false,
    };

    test('reads the widget and where it was written', () {
      final selection = WidgetSelection.fromInspectorNode(real)!;
      expect(selection.description, 'Text');
      expect(selection.createdByLocalProject, isTrue);
      expect(selection.location!.line, 107);
      expect(selection.location!.column, 19);
      expect(selection.location!.name, 'Text');
      expect(selection.location!.asEditorTarget, endsWith('main.dart:107:19'));
    });

    test('a release build has a widget and no location', () {
      final node = Map<String, Object?>.from(real)..remove('creationLocation');
      final selection = WidgetSelection.fromInspectorNode(node)!;
      expect(selection.description, 'Text');
      expect(selection.location, isNull);
      expect(
        selection.toPromptText(),
        contains('This build carries no widget locations'),
      );
    });

    test('nothing selected is a real answer, not a malformed one', () {
      expect(WidgetSelection.fromInspectorNode(null), isNull);
      expect(
        WidgetSelection.fromInspectorNode(const <String, Object?>{}),
        isNull,
      );
    });

    test('a framework widget says so', () {
      final node = Map<String, Object?>.from(real)
        ..['createdByLocalProject'] = false;
      expect(
        WidgetSelection.fromInspectorNode(node)!.toPromptText(),
        contains('framework or a package'),
      );
    });
  });

  group('WidgetSourceLocation.fromNavigateEvent', () {
    test('reads the framework push', () {
      // Captured 2026-09-08 off the ToolEvent stream.
      final location =
          WidgetSourceLocation.fromNavigateEvent(const <Object?, Object?>{
            'fileUri': 'file:///C:/kw/probeapp/lib/main.dart',
            'line': 118,
            'column': 22,
            'source': 'flutter.inspector',
          })!;
      expect(location.line, 118);
      expect(location.column, 22);
    });

    test('refuses a payload missing the location', () {
      for (final data in const <Map<Object?, Object?>>[
        <Object?, Object?>{},
        <Object?, Object?>{'fileUri': '', 'line': 1, 'column': 1},
        <Object?, Object?>{'fileUri': 'file:///a.dart', 'line': 1},
      ]) {
        expect(WidgetSourceLocation.fromNavigateEvent(data), isNull);
      }
    });
  });
}
