import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Spacing, colour, spinners and tab headers, asserted rather than audited
/// (round 69). Each debt set is a ratchet: no file may join it, and a file
/// that is cleaned must leave it.
void main() {
  final roots = [Directory('lib'), Directory('../packages/karmashala_ui/lib')];

  /// Where a raw number or colour may be named.
  const tokenLayer = {
    '../packages/karmashala_ui/lib/src/design_tokens.dart',
    '../packages/karmashala_ui/lib/src/app_theme.dart',
  };

  Map<String, String> sources() {
    for (final root in roots) {
      expect(root.existsSync(), isTrue, reason: 'run from the app root');
    }
    return {
      for (final root in roots)
        for (final file in root.listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart'))
            file.path.replaceAll(r'\', '/'): file
                .readAsStringSync()
                .split('\n')
                .map((line) {
                  final comment = line.indexOf('//');
                  return comment == -1 ? line : line.substring(0, comment);
                })
                .join('\n'),
    };
  }

  int lineOf(String source, int offset) =>
      '\n'.allMatches(source.substring(0, offset)).length + 1;

  /// The argument list of the call whose `(` is at [open].
  String argsAt(String source, int open) {
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) return source.substring(open + 1, i);
    }
    return source.substring(open + 1);
  }

  final edgeInsets = RegExp(r'(?<![\w$])EdgeInsets(?:Directional)?\.\w+\(');

  /// A number that is not zero, not a multiplier of a token, and not an
  /// argument to `clamp` — the shapes a token-built inset legitimately has.
  bool hasLiteral(String args) {
    final cleaned = args.replaceAll(RegExp(r'\.clamp\([^)]*\)'), '');
    for (final m in RegExp(
      r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])',
    ).allMatches(cleaned)) {
      if (double.parse(m.group(1)!) == 0) continue;
      final before = cleaned.substring(0, m.start).trimRight();
      if (before.endsWith('*')) continue;
      return true;
    }
    return false;
  }

  List<String> literalInsets(Map<String, String> all) => [
    for (final MapEntry(key: path, value: source) in all.entries)
      if (!tokenLayer.contains(path))
        for (final m in edgeInsets.allMatches(source))
          if (hasLiteral(argsAt(source, m.end - 1)))
            '$path:${lineOf(source, m.start)}',
  ];

  test('no literal number in an EdgeInsets', () {
    expect(
      literalInsets(sources()),
      isEmpty,
      reason:
          'spacing comes from Insets (hair, xxs, xs, sm, md, lg, xl, xxl) or '
          'a named token in design_tokens.dart',
    );
  });

  final gap = RegExp(
    r'SizedBox\(\s*(?:width|height):\s*(\d+(?:\.\d+)?)\s*,?\s*\)',
  );

  test('no literal gap in a SizedBox', () {
    final found = <String>[];
    sources().forEach((path, source) {
      if (tokenLayer.contains(path)) return;
      for (final m in gap.allMatches(source)) {
        if (double.parse(m.group(1)!) == 0) continue;
        found.add('$path:${lineOf(source, m.start)}');
      }
    });
    expect(found, isEmpty, reason: 'a gap is an Insets token');
  });

  test('no raw Color(0x…) outside the token layer', () {
    // A user-picked accent and the white canvas a web page assumes are
    // palettes of their own, named once each.
    const palettes = {
      '../packages/karmashala_ui/lib/src/appearance.dart',
      'lib/src/features/artifacts/presentation/html_preview.dart',
    };
    final found = <String>[];
    sources().forEach((path, source) {
      if (tokenLayer.contains(path) || palettes.contains(path)) return;
      for (final m in RegExp(r'(?<![\w$])Color\(0x').allMatches(source)) {
        found.add('$path:${lineOf(source, m.start)}');
      }
    });
    expect(found, isEmpty, reason: 'use the ColorScheme or SemanticColors');
  });

  test('no Material spinner outside InlineSpinner', () {
    // Material's ring holds a vsync ticker: one on screen repaints the app
    // at 60 fps. A determinate tab-progress ring is not a spinner.
    const allowed = {
      '../packages/karmashala_ui/lib/src/inline_spinner.dart',
      'lib/src/features/terminal/presentation/tab_progress_mark.dart',
    };
    final found = <String>[];
    sources().forEach((path, source) {
      if (allowed.contains(path)) return;
      for (final m in RegExp(
        r'(?<![\w$])CircularProgressIndicator\(',
      ).allMatches(source)) {
        found.add('$path:${lineOf(source, m.start)}');
      }
    });
    expect(found, isEmpty, reason: 'use InlineSpinner with a size slot');
  });

  test('every top-level tab declares its header', () {
    // What a pane id becomes, and the one header each wears: a page tab the
    // shared bar, a document tab the pane header, and a tool whose first row
    // is its working toolbar — named here so a new tab must choose.
    const scaffold = 'WorkbenchTabScaffold(';
    const paneHeader = 'PaneHeader(';
    const tabs = <String, (String, String?)>{
      'UsageTabView': (
        'lib/src/features/agents/presentation/usage_tab/usage_tab_view.dart',
        scaffold,
      ),
      'StoresTabView': (
        'lib/src/features/stores/presentation/stores_tab_view.dart',
        scaffold,
      ),
      'LogsTabView': ('lib/src/app/shell/logs_tab_view.dart', scaffold),
      'OverviewTabView': (
        'lib/src/features/overview/presentation/overview_tab_view.dart',
        scaffold,
      ),
      'RunningTabView': ('lib/src/app/shell/running_tab_view.dart', scaffold),
      'WorkflowsTabView': (
        'lib/src/features/workflows/presentation/workflows_tab_view.dart',
        scaffold,
      ),
      'EditorTabView': (
        'lib/src/features/editor/presentation/editor_tab_view.dart',
        paneHeader,
      ),
      'MediaPane': (
        'lib/src/features/editor/presentation/media/media_tab_view.dart',
        paneHeader,
      ),
      'NoteTabView': (
        'lib/src/features/notes/presentation/note_tab_view.dart',
        paneHeader,
      ),
      'DiffTabView': (
        'lib/src/features/git/presentation/diff_tab_view.dart',
        paneHeader,
      ),
      // Toolbar-first tools: the settings nav, the address bar, the folder
      // breadcrumb, the device toolbar, a terminal's region header.
      'SettingsTabView': (
        'lib/src/features/settings/presentation/settings_tab_view.dart',
        null,
      ),
      'BrowserPane': (
        'lib/src/features/browser/presentation/browser_pane.dart',
        null,
      ),
      'FilesTabView': (
        'lib/src/features/files/presentation/files_tab_view.dart',
        null,
      ),
      'DevicePane': ('', null),
      'LiveTerminalPane': ('', null),
    };
    final regions = File(
      'lib/src/features/terminal/presentation/terminal_pane_regions.dart',
    ).readAsStringSync();
    final built = RegExp(
      r'(?<![A-Za-z_.])([A-Z]\w*(?:TabView|Pane))(?=(?:\.\w+)?\()',
    ).allMatches(regions).map((m) => m.group(1)!).toSet();
    expect(built, isNotEmpty, reason: 'the tab dispatch has moved');
    expect(
      built.difference(tabs.keys.toSet()),
      isEmpty,
      reason: 'a new top-level tab: declare its header here',
    );
    final all = sources();
    tabs.forEach((name, entry) {
      final (path, header) = entry;
      if (header == null) return;
      expect(all[path], contains(header), reason: '$name in $path');
    });
  });

  test('the guards can fail', () {
    String args(String call) => argsAt(call, call.indexOf('('));
    expect(hasLiteral(args('EdgeInsets.only(top: 2)')), isTrue);
    expect(hasLiteral(args('EdgeInsets.all(Insets.xs + 2)')), isTrue);
    expect(hasLiteral(args('EdgeInsets.only(top: Insets.xxs)')), isFalse);
    expect(
      hasLiteral(args('EdgeInsets.fromLTRB(0, Insets.sm, 0, 0)')),
      isFalse,
    );
    expect(hasLiteral(args('EdgeInsets.only(left: Insets.lg * 2)')), isFalse);
    expect(
      hasLiteral(args('EdgeInsets.only(left: Insets.md * d.clamp(0, 6))')),
      isFalse,
    );
    expect(gap.hasMatch('const SizedBox(width: 6)'), isTrue);
    expect(gap.hasMatch('SizedBox(width: Insets.xs)'), isFalse);
    expect(gap.hasMatch('SizedBox(width: 6, child: x)'), isFalse);
    // The token layer still has literals, so the sweep is still reading.
    final tokens = sources()[tokenLayer.first]!;
    expect(edgeInsets.hasMatch(tokens) || tokens.contains('= 2.0'), isTrue);
  });
}
