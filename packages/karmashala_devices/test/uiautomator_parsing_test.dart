import 'dart:io';

import 'package:karmashala_devices/src/data/uiautomator_parsing.dart';
import 'package:karmashala_devices/src/domain/device_input.dart';
import 'package:karmashala_devices/src/domain/ui_node.dart';
import 'package:test/test.dart';

/// Real `uiautomator dump` output, captured from the devices this project is
/// developed against. Synthetic XML would not have caught the two findings that
/// shaped the query interface: a Flutter app puts its labels in `content-desc`
/// and leaves `text` empty, and the Settings list is full of `&amp;` and
/// non-ASCII punctuation.
String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

/// The emulator's Settings home screen (`com.android.settings`, 1080x2400).
String get _settingsDump => _fixture('uiautomator_settings.xml');

/// A Flutter app (`com.popupbits.aakar`) on the physical OPPO, 1080x2340.
String get _flutterDump => _fixture('uiautomator_flutter.xml');

void main() {
  group('UiBounds.parse', () {
    test('parses the exact [l,t][r,b] form', () {
      final bounds = UiBounds.parse('[891,275][1017,401]');
      expect(bounds, isNotNull);
      expect(bounds!.left, 891);
      expect(bounds.top, 275);
      expect(bounds.right, 1017);
      expect(bounds.bottom, 401);
    });

    test('centres the way the verified loop-27 example does', () {
      // The pane's coordinate mapping was verified end to end against this
      // exact rectangle: centre (954, 338) on a 1080x2400 screen.
      expect(UiBounds.parse('[891,275][1017,401]')!.center, (x: 954, y: 338));
    });

    test('accepts negative coordinates for scrolled-away nodes', () {
      final bounds = UiBounds.parse('[0,-120][1080,-8]')!;
      expect(bounds.top, -120);
      expect(bounds.center, (x: 540, y: -64));
    });

    test('reports zero-area rectangles as empty', () {
      expect(UiBounds.parse('[10,10][10,10]')!.isEmpty, isTrue);
      expect(UiBounds.parse('[10,10][10,40]')!.isEmpty, isTrue);
      expect(UiBounds.parse('[10,10][40,40]')!.isEmpty, isFalse);
    });

    test('rejects anything that is not exactly the bounds form', () {
      // A wrong centre point taps the wrong thing and reports success, so
      // near-misses must not parse.
      for (final raw in [
        '',
        '[0,0]',
        '[0,0][1080]',
        '[0,0][1080,2400',
        '0,0,1080,2400',
        '[0,0][1080,2400][1,1]',
        '[a,0][1080,2400]',
        '[0.5,0][1080,2400]',
      ]) {
        expect(UiBounds.parse(raw), isNull, reason: 'should reject "$raw"');
      }
      expect(UiBounds.parse(null), isNull);
    });

    test('tolerates surrounding whitespace', () {
      expect(UiBounds.parse('  [0,0][10,10] '), UiBounds.parse('[0,0][10,10]'));
    });

    test('centerIsOnScreen catches nodes scrolled out of the viewport', () {
      const screen = DeviceScreenSize(width: 1080, height: 2400);
      expect(
        UiBounds.parse('[0,100][1080,300]')!.centerIsOnScreen(screen),
        isTrue,
      );
      expect(
        UiBounds.parse('[0,-400][1080,-200]')!.centerIsOnScreen(screen),
        isFalse,
      );
      expect(
        UiBounds.parse('[0,2500][1080,2700]')!.centerIsOnScreen(screen),
        isFalse,
      );
    });
  });

  group('decodeXmlEntities', () {
    test('decodes the five predefined entities', () {
      expect(
        decodeXmlEntities('a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;'),
        '''a & b <c> "d" 'e\'''',
      );
    });

    test('decodes numeric references, which carry real newlines', () {
      // A Flutter clock widget's content-desc is four lines in one attribute.
      expect(decodeXmlEntities('6:47 AM&#10;Sunday'), '6:47 AM\nSunday');
      expect(decodeXmlEntities('&#x41;&#x42;'), 'AB');
    });

    test('leaves unknown entities exactly as they were', () {
      expect(decodeXmlEntities('a &nbsp; b'), 'a &nbsp; b');
      expect(decodeXmlEntities('Tom & Jerry'), 'Tom & Jerry');
      expect(decodeXmlEntities('&#xZZ;'), '&#xZZ;');
    });

    test('is a no-op for text with no ampersand', () {
      expect(decodeXmlEntities('plain text'), 'plain text');
    });
  });

  group('parseUiAutomatorXml on real dumps', () {
    test('parses the emulator Settings screen', () {
      final tree = parseUiAutomatorXml(_settingsDump);
      expect(tree.isEmpty, isFalse);
      expect(tree.rotation, 0);
      expect(tree.packageName, 'com.android.settings');
      expect(tree.nodeCount, greaterThan(50));
      expect(tree.roots.single.bounds, UiBounds.parse('[0,0][1080,2400]'));
    });

    test('decodes entities in real screen text', () {
      final tree = parseUiAutomatorXml(_settingsDump);
      final labels = [for (final node in tree.allNodes) node.text];
      expect(labels, contains('Network & internet'));
      expect(labels, contains('Sound & vibration'));
    });

    test('reads the flags that decide whether a node can be tapped', () {
      final tree = parseUiAutomatorXml(_settingsDump);
      final row = tree.findFirst(
        const UiElementQuery(text: 'Network & internet'),
      )!;
      expect(row.className, 'android.widget.TextView');
      expect(row.enabled, isTrue);
      expect(row.bounds, isNotNull);
      // The list itself is the scrollable one, not the row.
      expect(
        tree.allNodes.where((n) => n.scrollable).length,
        greaterThanOrEqualTo(1),
      );
    });

    test('parses a Flutter app, whose labels live in content-desc', () {
      final tree = parseUiAutomatorXml(_flutterDump);
      expect(tree.packageName, 'com.popupbits.aakar');
      // Not one node on the whole screen has text.
      expect(tree.allNodes.every((node) => node.text.isEmpty), isTrue);
      final phone = tree.findFirst(const UiElementQuery(text: 'Phone'))!;
      expect(phone.contentDescription, 'Phone');
      expect(phone.className, 'android.widget.Button');
      expect(phone.clickable, isTrue);
      expect(phone.bounds, UiBounds.parse('[12,1410][188,1653]'));
      expect(phone.label, 'Phone');
    });

    test('keeps a multi-line content-desc intact', () {
      final tree = parseUiAutomatorXml(_flutterDump);
      final clock = tree.allNodes.firstWhere(
        (node) => node.contentDescription.contains('Bhadra'),
      );
      expect(clock.contentDescription, contains('\n'));
      expect(clock.contentDescription.split('\n').length, 4);
    });

    test('every node with bounds has a centre inside its own rectangle', () {
      for (final dump in [_settingsDump, _flutterDump]) {
        for (final node in parseUiAutomatorXml(dump).allNodes) {
          final bounds = node.bounds;
          if (bounds == null || bounds.isEmpty) continue;
          final c = bounds.center;
          expect(c.x, inInclusiveRange(bounds.left, bounds.right));
          expect(c.y, inInclusiveRange(bounds.top, bounds.bottom));
        }
      }
    });

    test('preserves parent/child structure and paths', () {
      final tree = parseUiAutomatorXml(_settingsDump);
      final row = tree.findFirst(
        const UiElementQuery(text: 'Network & internet'),
      )!;
      expect(row.parent, isNotNull);
      expect(row.ancestors.last, tree.roots.single);
      expect(row.depth, greaterThan(2));
      expect(row.path.split('/').length, row.depth);
      expect(tree.roots.single.path, '');
    });
  });

  group('parseUiAutomatorXml on the shapes real devices actually emit', () {
    test('empty input yields an empty hierarchy rather than throwing', () {
      expect(parseUiAutomatorXml('').isEmpty, isTrue);
      expect(parseUiAutomatorXml('   \n  ').isEmpty, isTrue);
    });

    test('a hierarchy with no nodes is empty, not an error', () {
      // What a dump taken mid-transition can legitimately look like.
      expect(
        parseUiAutomatorXml(
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<hierarchy rotation="0" />',
        ).isEmpty,
        isTrue,
      );
    });

    test('unescaped markup inside an attribute does not break the tree', () {
      // A conforming XML parser rejects the whole document for this. Scanning
      // only to the closing quote means the value survives verbatim.
      final tree = parseUiAutomatorXml(
        '<hierarchy rotation="0">'
        '<node index="0" text="Tom & Jerry <b>" class="android.widget.TextView" '
        'bounds="[0,0][100,50]" clickable="true" />'
        '</hierarchy>',
      );
      expect(tree.nodeCount, 1);
      expect(tree.roots.single.text, 'Tom & Jerry <b>');
      expect(tree.roots.single.clickable, isTrue);
    });

    test('truncated output keeps the nodes that completed', () {
      final full = _settingsDump;
      final cut = full.substring(0, full.length ~/ 2);
      final tree = parseUiAutomatorXml(cut);
      expect(tree.isEmpty, isFalse);
      expect(tree.nodeCount, greaterThan(5));
      expect(tree.nodeCount, lessThan(parseUiAutomatorXml(full).nodeCount));
    });

    test('a start tag cut mid-attribute keeps what was read', () {
      final tree = parseUiAutomatorXml(
        '<hierarchy rotation="0">'
        '<node index="0" class="android.widget.LinearLayout" '
        'bounds="[0,0][100,100]">'
        '<node index="0" text="Half a nod',
      );
      expect(tree.nodeCount, 2);
      expect(tree.allNodes.last.text, 'Half a nod');
    });

    test('missing attributes fall back sensibly', () {
      final tree = parseUiAutomatorXml(
        '<hierarchy><node index="0" /></hierarchy>',
      );
      final node = tree.roots.single;
      expect(node.text, '');
      expect(node.className, '');
      expect(node.bounds, isNull);
      expect(node.clickable, isFalse);
      // Absent `enabled` means enabled: treating unknown as disabled would make
      // the enabled-only filter hide everything on such a device.
      expect(node.enabled, isTrue);
    });

    test('an unparseable bounds attribute leaves bounds null, not wrong', () {
      final tree = parseUiAutomatorXml(
        '<hierarchy><node index="0" bounds="0,0,100,100" /></hierarchy>',
      );
      expect(tree.roots.single.bounds, isNull);
    });

    test('a bare <node> root is accepted', () {
      final tree = parseUiAutomatorXml(
        '<node index="0" text="alone" bounds="[0,0][10,10]" />',
      );
      expect(tree.nodeCount, 1);
      expect(tree.roots.single.text, 'alone');
    });

    test('mismatched end tags do not discard the document', () {
      final tree = parseUiAutomatorXml(
        '<hierarchy>'
        '<node index="0" text="a"><node index="0" text="b" /></wrong>'
        '<node index="1" text="c" />'
        '</hierarchy>',
      );
      expect([for (final n in tree.allNodes) n.text], ['a', 'b', 'c']);
    });

    test('comments, CDATA and declarations are skipped', () {
      final tree = parseUiAutomatorXml(
        '<?xml version="1.0"?>'
        '<!DOCTYPE hierarchy>'
        '<hierarchy><!-- a comment --><node index="0" text="x" /></hierarchy>',
      );
      expect(tree.nodeCount, 1);
      expect(tree.roots.single.text, 'x');
    });

    test('non-node elements inside the tree are ignored', () {
      final tree = parseUiAutomatorXml(
        '<hierarchy><meta what="ever" /><node index="0" text="x" /></hierarchy>',
      );
      expect(tree.nodeCount, 1);
    });

    test('rotation is read from the hierarchy element', () {
      expect(
        parseUiAutomatorXml(
          '<hierarchy rotation="1"><node /></hierarchy>',
        ).rotation,
        1,
      );
      expect(
        parseUiAutomatorXml('<hierarchy><node /></hierarchy>').rotation,
        0,
      );
    });

    test('a deeply nested tree parses without recursion trouble', () {
      final buffer = StringBuffer('<hierarchy>');
      for (var i = 0; i < 2000; i++) {
        buffer.write('<node index="$i">');
      }
      buffer.write('</hierarchy>');
      expect(parseUiAutomatorXml(buffer.toString()).nodeCount, 2000);
    });
  });

  group('uiDumpFailure', () {
    test('accepts the success line, typo and all', () {
      expect(
        uiDumpFailure(
          'UI hierchary dumped to: /data/local/tmp/dump.xml\n',
          ok: true,
        ),
        isNull,
      );
    });

    test('flags an idle-state failure as retryable', () {
      // uiautomator prints this and still exits 0, so the exit status cannot be
      // the success test.
      final failure = uiDumpFailure(
        'ERROR: could not get idle state.',
        ok: true,
      );
      expect(failure, isNotNull);
      expect(failure!.retryable, isTrue);
      expect(failure.message, contains('idle'));
    });

    test('flags a null root node as retryable and explains why', () {
      final failure = uiDumpFailure(
        'ERROR: null root node returned by UiTestAutomationBridge.',
        ok: true,
      );
      expect(failure!.retryable, isTrue);
      expect(failure.message, contains('screen is'));
    });

    test('reports any other ERROR line without retrying', () {
      final failure = uiDumpFailure(
        'ERROR: could not create file /nope/dump.xml',
        ok: true,
      );
      expect(failure!.retryable, isFalse);
      expect(failure.message, contains('/nope/dump.xml'));
    });

    test('treats a non-zero exit as a failure', () {
      expect(uiDumpFailure('', ok: false), isNotNull);
      expect(uiDumpFailure('', ok: false)!.retryable, isFalse);
    });

    test('treats missing output as a failure even on exit 0', () {
      final failure = uiDumpFailure('', ok: true);
      expect(failure, isNotNull);
      expect(failure!.message, contains('printed nothing'));
    });

    test('reads the error off stderr as happily as stdout', () {
      expect(
        uiDumpFailure(
          '\nERROR: could not get idle state.',
          ok: true,
        )!.retryable,
        isTrue,
      );
    });
  });
}
