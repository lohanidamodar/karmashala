import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every search bar clears with one click: a search or filter box is built on
/// `SearchField`, which draws the Clear button, never on a bare `TextField`.
void main() {
  /// A bare text field that reads as a search box: a magnifier, or a hint that
  /// starts "Search", "Filter" or "Find".
  final bareField = RegExp(r'(?<![\w$])(TextField|TextFormField)\(');
  final magnifier = RegExp('magnif', caseSensitive: false);
  final searchHint = RegExp(
    r"hintText:[^;]{0,160}?'(Search|Filter|Find)\b",
    dotAll: true,
  );

  /// The argument list of the call whose `(` is at [open].
  String argumentsAt(String source, int open) {
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      final c = source[i];
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) return source.substring(open, i + 1);
    }
    return source.substring(open);
  }

  List<String> bareSearchFields(String path, String source) => [
    for (final match in bareField.allMatches(source))
      if (argumentsAt(source, match.end - 1) case final args
          when magnifier.hasMatch(args) || searchHint.hasMatch(args))
        '$path:${'\n'.allMatches(source.substring(0, match.start)).length + 1}',
  ];

  Map<String, String> sources() {
    final roots = [
      Directory('lib'),
      for (final package in Directory('../packages').listSync())
        if (package is Directory &&
            Directory('${package.path}/lib').existsSync())
          Directory('${package.path}/lib'),
    ];
    expect(roots.first.existsSync(), isTrue, reason: 'run from the app root');
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

  test('the guard sees a search box built on a bare TextField', () {
    const explorer = '''
      child: TextField(
        decoration: InputDecoration(
          prefixIcon: Icon(AppIcons.magnifyingGlass),
          hintText: 'Search projects',
        ),
      ),''';
    const terminal = '''
      child: TextField(
        decoration: InputDecoration(
          hintText: state.regex
              ? 'Find by pattern'
              : 'Find in scrollback',
        ),
      ),''';
    const composer = '''
      child: TextField(
        decoration: InputDecoration(hintText: 'Message the agent'),
      ),''';
    expect(bareSearchFields('e', explorer), ['e:1']);
    expect(bareSearchFields('t', terminal), ['t:1']);
    expect(bareSearchFields('c', composer), isEmpty);
    expect(bareSearchFields('s', 'SearchField(hintText: "Find")'), isEmpty);
  });

  test('no search box is a bare TextField', () {
    final found = <String>[];
    sources().forEach((path, source) {
      if (path.endsWith('karmashala_ui/lib/src/search_field.dart')) return;
      found.addAll(bareSearchFields(path, source));
    });
    expect(
      found,
      isEmpty,
      reason: 'build these on SearchField from karmashala_ui',
    );
  });

  test('every search bar named in round 13 is a SearchField', () {
    const searchBars = {
      'lib/src/app/shell/quick_open/quick_open_list.dart': 'quick open, tabs',
      'lib/src/app/shell/logs_tab_view.dart': 'logs tab filter',
      'lib/src/features/explorer/presentation/explorer_panel.dart': 'projects',
      'lib/src/features/sessions/presentation/filter_menu_field.dart':
          'project, checkout and branch pickers',
      'lib/src/features/terminal/presentation/terminal_search_bar.dart':
          'terminal find',
      'lib/src/features/settings/presentation/settings_nav.dart': 'settings',
      'lib/src/features/settings/presentation/keyboard_section.dart': 'keymap',
      'lib/src/features/settings/presentation/acp_registry_picker.dart':
          'agent registry',
      'lib/src/features/settings/presentation/choose_application_dialog.dart':
          'applications',
      'lib/src/features/stores/presentation/store_combine.dart': 'store apps',
      '../packages/karmashala_ui/lib/src/log_filter_controls.dart':
          'log, logcat, Flutter console and code find',
      '../packages/karmashala_ui/lib/src/file_browser_view/file_browser_rows.dart':
          'file browser filter',
    };
    final all = sources();
    for (final MapEntry(key: path, value: what) in searchBars.entries) {
      expect(
        all[path],
        contains('SearchField('),
        reason: '$what ($path) has no SearchField',
      );
    }
  });
}
