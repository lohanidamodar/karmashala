import 'dart:io';

import 'package:karmashala_devices/src/data/uiautomator_parsing.dart';
import 'package:karmashala_devices/src/domain/device_input.dart';
import 'package:karmashala_devices/src/domain/ui_node.dart';
import 'package:karmashala_devices/src/domain/ui_summary.dart';
import 'package:test/test.dart';

String _fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// The emulator's Settings home screen, 1080x2400.
UiHierarchy get _settings =>
    parseUiAutomatorXml(_fixture('uiautomator_settings.xml'));

/// A Flutter app on the physical OPPO, 1080x2340.
UiHierarchy get _flutterApp =>
    parseUiAutomatorXml(_fixture('uiautomator_flutter.xml'));

const _phoneScreen = DeviceScreenSize(width: 1080, height: 2400);

UiNode _node({
  String text = '',
  String contentDescription = '',
  String resourceId = '',
  String className = '',
  String bounds = '[0,0][100,100]',
  bool clickable = false,
  bool enabled = true,
  List<UiNode> children = const [],
}) => UiNode(
  text: text,
  contentDescription: contentDescription,
  resourceId: resourceId,
  className: className,
  bounds: UiBounds.parse(bounds),
  clickable: clickable,
  enabled: enabled,
  children: children,
);

void main() {
  group('UiElementQuery matching', () {
    test('text matches a substring, case-insensitively', () {
      final node = _node(text: 'Network & internet');
      expect(const UiElementQuery(text: 'network').matches(node), isTrue);
      expect(const UiElementQuery(text: 'INTERNET').matches(node), isTrue);
      expect(const UiElementQuery(text: 'bluetooth').matches(node), isFalse);
    });

    test('exact requires the whole value, still case-insensitively', () {
      final node = _node(text: 'Settings');
      expect(
        const UiElementQuery(text: 'setting', exact: true).matches(node),
        isFalse,
      );
      expect(
        const UiElementQuery(text: 'settings', exact: true).matches(node),
        isTrue,
      );
    });

    test('text also matches content-desc, because Flutter has no text', () {
      final node = _node(contentDescription: 'Sign in');
      expect(const UiElementQuery(text: 'sign in').matches(node), isTrue);
    });

    test('contentDescription matches only the description', () {
      final node = _node(text: 'Sign in');
      expect(
        const UiElementQuery(contentDescription: 'Sign in').matches(node),
        isFalse,
      );
    });

    test('resourceId matches the full id or its short form', () {
      final node = _node(resourceId: 'com.android.settings:id/search_action');
      expect(
        const UiElementQuery(resourceId: 'search_action').matches(node),
        isTrue,
      );
      expect(
        const UiElementQuery(
          resourceId: 'com.android.settings:id/search_action',
        ).matches(node),
        isTrue,
      );
      expect(const UiElementQuery(resourceId: 'other').matches(node), isFalse);
    });

    test('className matches the full name or its last segment', () {
      final node = _node(className: 'android.widget.Button');
      expect(const UiElementQuery(className: 'Button').matches(node), isTrue);
      expect(
        const UiElementQuery(className: 'android.widget.Button').matches(node),
        isTrue,
      );
      expect(
        const UiElementQuery(className: 'TextView').matches(node),
        isFalse,
      );
    });

    test('criteria are ANDed together', () {
      final node = _node(text: 'OK', className: 'android.widget.Button');
      expect(
        const UiElementQuery(text: 'OK', className: 'Button').matches(node),
        isTrue,
      );
      expect(
        const UiElementQuery(text: 'OK', className: 'TextView').matches(node),
        isFalse,
      );
    });

    test('clickableOnly and enabledOnly filter', () {
      final plain = _node(text: 'OK');
      final button = _node(text: 'OK', clickable: true);
      final disabled = _node(text: 'OK', clickable: true, enabled: false);
      const clickable = UiElementQuery(text: 'OK', clickableOnly: true);
      expect(clickable.matches(plain), isFalse);
      expect(clickable.matches(button), isTrue);
      const enabledClickable = UiElementQuery(
        text: 'OK',
        clickableOnly: true,
        enabledOnly: true,
      );
      expect(enabledClickable.matches(disabled), isFalse);
    });

    test('an empty needle never matches an empty value', () {
      // Otherwise `find(text: "")` would return every node in the tree.
      expect(const UiElementQuery(text: 'x').matches(_node()), isFalse);
    });
  });

  group('find ranking', () {
    test('an exact label beats a substring on the same screen', () {
      // Settings has both a "Settings" title and a "Search settings" box; an
      // agent asking for "Settings" means the first.
      final matches = _settings.find(const UiElementQuery(text: 'Settings'));
      expect(matches.length, greaterThan(1));
      expect(matches.first.text, 'Settings');
      expect([for (final n in matches) n.text], contains('Search settings'));
    });

    test('ties keep document order', () {
      final tree = UiHierarchy(
        roots: [
          _node(
            className: 'android.widget.LinearLayout',
            children: [
              _node(text: 'alpha one'),
              _node(text: 'alpha two'),
              _node(text: 'alpha three'),
            ],
          ),
        ],
      );
      expect(
        [
          for (final n in tree.find(const UiElementQuery(text: 'alpha')))
            n.text,
        ],
        ['alpha one', 'alpha two', 'alpha three'],
      );
    });

    test(
      'an exact content-desc beats a longer one that merely contains it',
      () {
        // Found on the physical OPPO: contentDesc "a" on a Flutter keyboard
        // ranked the clock widget first, whose description contains an "a".
        final tree = UiHierarchy(
          roots: [
            _node(
              className: 'android.widget.FrameLayout',
              children: [
                _node(contentDescription: '7:12 AM\nSunday\n2083 Bhadra 14'),
                _node(contentDescription: 'a'),
              ],
            ),
          ],
        );
        final matches = tree.find(
          const UiElementQuery(contentDescription: 'a'),
        );
        expect(matches, hasLength(2));
        expect(matches.first.contentDescription, 'a');
      },
    );

    test('an exact resource id outranks one that contains it', () {
      final tree = UiHierarchy(
        roots: [
          _node(
            className: 'android.widget.FrameLayout',
            children: [
              _node(resourceId: 'com.app:id/search_action_bar_title'),
              _node(resourceId: 'com.app:id/title'),
            ],
          ),
        ],
      );
      final matches = tree.find(const UiElementQuery(resourceId: 'title'));
      expect(matches.first.shortResourceId, 'title');
    });

    test('every criterion must match exactly to rank first', () {
      final almost = _node(text: 'OK', className: 'android.widget.TextView');
      final both = _node(text: 'OK', className: 'android.widget.Button');
      const query = UiElementQuery(text: 'OK', className: 'Button');
      expect(query.rank(both), 0);
      expect(query.rank(almost), 1);
    });

    test('limit truncates without reordering', () {
      final matches = _settings.find(
        const UiElementQuery(className: 'TextView'),
        limit: 3,
      );
      expect(matches, hasLength(3));
    });

    test('findFirst returns the best match, or null', () {
      expect(
        _settings.findFirst(const UiElementQuery(text: 'Storage'))?.text,
        'Storage',
      );
      expect(
        _settings.findFirst(const UiElementQuery(text: 'nothing here at all')),
        isNull,
      );
    });
  });

  group('tap targets', () {
    test('a node with area taps its own centre', () {
      final node = _node(bounds: '[100,200][300,400]');
      expect(node.tapBounds!.center, (x: 200, y: 300));
    });

    test('a zero-sized node falls back to the nearest ancestor with area', () {
      // Compose and Flutter both emit semantically real, visually empty nodes.
      final child = _node(text: 'ghost', bounds: '[50,50][50,50]');
      _node(
        bounds: '[0,0][200,100]',
        className: 'android.widget.FrameLayout',
        children: [child],
      );
      expect(child.tapBounds!.center, (x: 100, y: 50));
    });

    test('does not climb to a clickable ancestor when it has its own area', () {
      // The reason this matters: inside a list the nearest clickable ancestor
      // is the list itself, whose centre is a completely different row.
      final row = _node(text: 'Storage', bounds: '[0,1600][1080,1780]');
      _node(
        bounds: '[0,300][1080,2400]',
        clickable: true,
        className: 'androidx.recyclerview.widget.RecyclerView',
        children: [row],
      );
      expect(row.tapBounds!.center.y, 1690);
    });

    test('the Settings row centres inside its own bounds', () {
      final row = _settings.findFirst(
        const UiElementQuery(text: 'Network & internet'),
      )!;
      final bounds = row.tapBounds!;
      final centre = bounds.center;
      expect(centre.x, inInclusiveRange(bounds.left, bounds.right));
      expect(centre.y, inInclusiveRange(bounds.top, bounds.bottom));
      expect(bounds.centerIsOnScreen(_phoneScreen), isTrue);
    });
  });

  group('node accessors', () {
    test('shortResourceId strips the package prefix', () {
      expect(
        _node(resourceId: 'com.android.settings:id/title').shortResourceId,
        'title',
      );
      expect(_node(resourceId: 'title').shortResourceId, 'title');
      expect(_node().shortResourceId, '');
    });

    test('shortClassName keeps the last segment', () {
      expect(
        _node(className: 'android.widget.Button').shortClassName,
        'Button',
      );
      expect(_node(className: 'Button').shortClassName, 'Button');
    });

    test('label prefers text and falls back to content-desc', () {
      expect(_node(text: 'a', contentDescription: 'b').label, 'a');
      expect(_node(contentDescription: 'b').label, 'b');
      expect(_node().label, '');
    });

    test('isInteresting keeps text and behaviour, drops bare layout', () {
      expect(
        _node(className: 'android.widget.FrameLayout').isInteresting,
        isFalse,
      );
      expect(_node(text: 'hello').isInteresting, isTrue);
      expect(_node(contentDescription: 'hello').isInteresting, isTrue);
      expect(_node(clickable: true).isInteresting, isTrue);
    });
  });

  group('compact rendering', () {
    test('renders one node as coordinates first, then identity', () {
      final line = describeUiNode(
        _node(
          text: 'Sign in',
          resourceId: 'com.app:id/sign_in',
          className: 'android.widget.Button',
          bounds: '[100,200][300,400]',
          clickable: true,
        ),
        screen: _phoneScreen,
      );
      expect(line, '(200,300) 200x200 Button "Sign in" #sign_in [c]');
    });

    test('omits a content-desc that merely repeats the text', () {
      final line = describeUiNode(
        _node(text: 'Sign in', contentDescription: 'Sign in'),
      );
      expect(line, isNot(contains('~')));
    });

    test('keeps every node on one line', () {
      final line = describeUiNode(
        _node(contentDescription: '6:47 AM\nSunday\n2083 Bhadra 14'),
      );
      expect(line, isNot(contains('\n')));
      expect(line, contains(r'\n'));
    });

    test('flags an off-screen node so it is not tapped blind', () {
      final line = describeUiNode(
        _node(text: 'below the fold', bounds: '[0,2600][1080,2700]'),
        screen: _phoneScreen,
      );
      expect(line, endsWith('[o]'));
    });

    test('elides a very long label', () {
      final line = describeUiNode(_node(text: 'x' * 400));
      expect(line, contains('…'));
      expect(line.length, lessThan(140));
    });

    test('survives a node with no bounds at all', () {
      final line = describeUiNode(UiNode(text: 'nowhere'));
      expect(line, startsWith('(no bounds)'));
    });
  });

  group('pruning', () {
    test('keeps a small fraction of a real screen', () {
      final tree = _settings;
      final kept = interestingNodes(tree);
      expect(kept, isNotEmpty);
      expect(kept.length, lessThan(tree.nodeCount));
      // Every visible label survives the prune — that is the whole contract.
      for (final label in const [
        'Network & internet',
        'Connected devices',
        'Apps',
        'Notifications',
        'Battery',
        'Storage',
      ]) {
        expect(
          [for (final node in kept) node.text],
          contains(label),
          reason: '$label must survive pruning',
        );
      }
    });

    test('is dramatically cheaper than the raw dump', () {
      // The reason the pruned listing exists. Tokens are roughly characters/4
      // for both forms, so the character ratio is the honest comparison.
      final raw = _fixture('uiautomator_settings.xml');
      final rendered = renderUiElements(
        interestingNodes(_settings),
        screen: _phoneScreen,
      );
      expect(rendered.listing.length * 10, lessThan(raw.length));
    });

    test('a Flutter screen prunes to its content-desc nodes', () {
      final kept = interestingNodes(_flutterApp);
      expect([for (final n in kept) n.label], contains('Phone'));
      expect([for (final n in kept) n.label], contains('Chrome'));
    });

    test('limit reports how many were dropped', () {
      final nodes = interestingNodes(_settings);
      final result = renderUiElements(nodes, limit: 3);
      expect(result.shown, 3);
      expect(result.truncated, nodes.length - 3);
      expect(result.listing.split('\n'), hasLength(3));
    });
  });

  group('full tree rendering', () {
    test('includes every node, indented by depth', () {
      final tree = _settings;
      final lines = renderUiTree(tree, screen: _phoneScreen).split('\n');
      expect(lines, hasLength(tree.nodeCount));
      expect(lines.first, isNot(startsWith(' ')));
      expect(lines.any((line) => line.startsWith('  ')), isTrue);
    });
  });
}
