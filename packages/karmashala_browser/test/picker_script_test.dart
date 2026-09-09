import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

void main() {
  group('buildPickerScript', () {
    test('substitutes the binding name and the namespace', () {
      final script = buildPickerScript(
        bindingName: 'myBinding',
        namespace: 'myNamespace',
      );
      expect(script, contains("window['myBinding'](JSON.stringify(payload))"));
      expect(script, contains("var NS = 'myNamespace';"));
      expect(script, isNot(contains('__BINDING__')));
      expect(script, isNot(contains('__NAMESPACE__')));
    });

    test('defaults to the shared binding and namespace names', () {
      final script = buildPickerScript();
      expect(script, contains(kPickerBindingName));
      expect(script, contains(kPickerNamespace));
    });

    test('removes every listener it adds', () {
      final script = buildPickerScript();
      final added = RegExp(
        r"addEventListener\('(\w+)'",
      ).allMatches(script).map((m) => m.group(1)).toSet();
      final removed = RegExp(
        r"removeEventListener\('(\w+)'",
      ).allMatches(script).map((m) => m.group(1)).toSet();
      expect(added, isNotEmpty);
      expect(removed, added);
    });

    test('tears itself down before reporting, so the highlight is never in '
        'the screenshot', () {
      final script = buildPickerScript();
      final stopIndex = script.indexOf('    stop();\n    report(payload);');
      expect(stopIndex, greaterThan(-1));
    });

    test('the overlay cannot swallow the clicks it highlights', () {
      expect(buildPickerScript(), contains('pointer-events:none'));
    });

    test('reads the composed path so shadow-DOM elements can be picked', () {
      expect(buildPickerScript(), contains('e.composedPath()'));
    });

    test(
      'only reports a selector it verified resolves back to the element',
      () {
        expect(
          buildPickerScript(),
          contains('document.querySelector(selector) === el ? selector : null'),
        );
      },
    );
  });

  group('buildPickerStopScript', () {
    test('calls stop on the parked namespace', () {
      expect(
        buildPickerStopScript(namespace: 'ns'),
        "(function(){var p=window['ns'];if(p&&p.stop)"
        '{p.stop();return true;}return false;})()',
      );
    });
  });

  group('buildDescribeSelectorScript', () {
    test('escapes the selector as a JavaScript string literal', () {
      final script = buildDescribeSelectorScript('[data-x="a"]');
      expect(script, contains(r'document.querySelector("[data-x=\"a\"]")'));
    });

    test('reports the box in page coordinates', () {
      final script = buildDescribeSelectorScript('#go');
      expect(script, contains('r.left+window.scrollX'));
      expect(script, contains('r.top+window.scrollY'));
    });

    test('returns null when nothing matches, rather than throwing', () {
      expect(
        buildDescribeSelectorScript('#go'),
        contains('if(!el)return null'),
      );
    });

    test('produces the same payload shape the picker reports', () {
      final script = buildDescribeSelectorScript('#go');
      for (final key in [
        'ok:true',
        'selector:',
        'tagName:',
        'classNames:',
        'box:',
        'url:',
        'title:',
      ]) {
        expect(script, contains(key));
      }
    });
  });
}
