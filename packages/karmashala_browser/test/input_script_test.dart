import 'package:karmashala_browser/browser.dart';
import 'package:test/test.dart';

void main() {
  group('buildFindElementsScript', () {
    test('encodes the selector and the text as JavaScript literals', () {
      final script = buildFindElementsScript(selector: '[data-x="a"]');
      expect(script, contains(r'var SEL = "[data-x=\"a\"]"'));
      expect(script, contains('var NEEDLE = null'));
    });

    test('an invalid selector is reported, not thrown into the page', () {
      expect(
        buildFindElementsScript(selector: 'x'),
        contains("return { error: 'invalid selector: ' + err.message };"),
      );
    });

    test('a text search reads the label a person actually sees', () {
      final script = buildFindElementsScript(text: 'Sign in');
      for (final source in [
        "getAttribute('aria-label')",
        "getAttribute('placeholder')",
        "getAttribute('title')",
        'el.innerText',
      ]) {
        expect(script, contains(source));
      }
    });

    test('keeps the innermost match, so a wrapper is never returned for its '
        "child's text", () {
      expect(
        buildFindElementsScript(text: 'Go'),
        contains('hits[j].el.contains(hits[k].el)'),
      );
    });

    test('ranks exact over prefix over substring', () {
      final script = buildFindElementsScript(text: 'Go');
      expect(script, contains('if (hay === needle) rank = 0;'));
      expect(script, contains('rank = 1'));
      expect(script, contains('rank = 2'));
    });

    test('an exact search skips the prefix and substring ranks', () {
      expect(
        buildFindElementsScript(text: 'Go', exact: true),
        contains('var EXACT = true'),
      );
    });

    test('reports the box in page coordinates, like every other capture', () {
      final script = buildFindElementsScript(selector: '*');
      expect(script, contains('r.left + window.scrollX'));
      expect(script, contains('r.top + window.scrollY'));
    });

    test('carries the visibility filter and the limit', () {
      final script = buildFindElementsScript(
        selector: '*',
        visibleOnly: false,
        limit: 3,
      );
      expect(script, contains('var VISIBLE_ONLY = false'));
      expect(script, contains('var LIMIT = 3'));
    });
  });

  group('buildClickTargetScript', () {
    test('scrolls instantly, because a smooth scroll is still moving when the '
        'rect is read', () {
      expect(buildClickTargetScript('#go'), contains("behavior: 'instant'"));
    });

    test('reads the rect after the scroll and hit-tests the point', () {
      final script = buildClickTargetScript('#go');
      final afterScroll = script.substring(script.indexOf('el.scrollIntoView'));
      expect(afterScroll, contains('var r = el.getBoundingClientRect();'));
      expect(afterScroll, contains('document.elementFromPoint(cx, cy)'));
    });

    test('accepts a hit on the element, its descendant or its ancestor', () {
      expect(
        buildClickTargetScript('#go'),
        contains('hit === el || el.contains(hit) || hit.contains(el)'),
      );
    });

    test('has a distinct reason for each way a click can be impossible', () {
      final script = buildClickTargetScript('#go');
      for (final reason in ['gone', 'empty', 'offscreen', 'covered']) {
        expect(script, contains("reason: '$reason'"));
      }
    });
  });

  group('buildPrepareFieldScript', () {
    test('matches a select option by value or by its visible label', () {
      final script = buildPrepareFieldScript('#colour', 'Green');
      expect(
        script,
        contains(
          'option.value === VALUE || String(option.text).trim() === VALUE',
        ),
      );
      expect(script, contains('var VALUE = "Green"'));
    });

    test('fires input and change so a framework notices the select', () {
      final script = buildPrepareFieldScript('#colour', 'Green');
      expect(script, contains("new Event('input', { bubbles: true })"));
      expect(script, contains("new Event('change', { bubbles: true })"));
    });

    test('selects what is already there, so the fill replaces it', () {
      final script = buildPrepareFieldScript('#email', 'a');
      expect(script, contains('el.select()'));
      expect(script, contains('range.selectNodeContents(el)'));
    });

    test('refuses the input types that hold no text', () {
      expect(
        buildPrepareFieldScript('#x', 'a'),
        contains("['checkbox', 'radio', 'file', 'button', 'submit',"),
      );
    });

    test('reports whether the focus actually landed', () {
      expect(
        buildPrepareFieldScript('#x', 'a'),
        contains('focused: document.activeElement === el'),
      );
    });
  });

  test('buildReadFieldScript reads a value or a contenteditable', () {
    final script = buildReadFieldScript('#email');
    expect(script, contains('document.querySelector("#email")'));
    expect(script, contains('el.value!==undefined'));
    expect(script, contains('el.isContentEditable'));
  });

  group('the shared selector helper', () {
    test('is the same code the picker injects', () {
      expect(buildPickerScript(), contains(kUniqueSelectorJs.trim()));
      expect(
        buildFindElementsScript(selector: '*'),
        contains(kUniqueSelectorJs.trim()),
      );
    });

    test('never reports a selector it did not verify', () {
      expect(
        kUniqueSelectorJs,
        contains('document.querySelector(selector) === el ? selector : null'),
      );
    });
  });
}
