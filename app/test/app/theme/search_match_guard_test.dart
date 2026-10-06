import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every search matches one way: through `matchesSearch` / `searchMatch` from
/// `karmashala_core`, so "appwrite ai workdir" finds `appwrite-ai-workdir`
/// wherever it is typed. A plain lowercase `contains` does not.
void main() {
  /// A lowercased haystack tested against a query-like variable.
  final plainContains = RegExp(
    r'toLowerCase\(\)\??\.(contains|startsWith)\('
    r'(query|needle|filter|search|term|q|lower|wanted)\w*\)',
  );

  List<String> plainSearches(String path, String source) => [
    for (final match in plainContains.allMatches(source))
      '$path:${'\n'.allMatches(source.substring(0, match.start)).length + 1}',
  ];

  Map<String, String> sources() {
    final roots = [
      Directory('lib'),
      Directory('../server/lib'),
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

  test('the guard sees a plain lowercase contains', () {
    expect(plainSearches('a', 'p.name.toLowerCase().contains(query) ||'), [
      'a:1',
    ]);
    expect(
      plainSearches('b', "x\nentry.label?.toLowerCase().contains(needle)"),
      ['b:2'],
    );
    expect(
      plainSearches('c', "line.toLowerCase().contains('error:')"),
      isEmpty,
    );
    expect(plainSearches('d', 'matchesSearch(query, p.name)'), isEmpty);
  });

  /// Not searches a person types: each says why a substring is right there.
  const exempt = {
    // A bundle id narrowing log lines, documented to the caller as a substring.
    'karmashala_devices/lib/src/data/simulator_device_driver.dart',
    'karmashala_core/lib/src/util/search_match.dart',
  };

  test('no search filters with a plain lowercase contains', () {
    final found = <String>[];
    sources().forEach((path, source) {
      if (exempt.any(path.endsWith)) return;
      found.addAll(plainSearches(path, source));
    });
    expect(
      found,
      isEmpty,
      reason: 'match with matchesSearch or searchMatch from karmashala_core',
    );
  });

  test('every search named in round 15 uses the shared matcher', () {
    const searches = {
      'lib/src/app/shell/quick_open/fuzzy_match.dart': 'quick open ranking',
      'lib/src/app/shell/quick_open/quick_open_item.dart': 'quick open whole',
      'lib/src/app/shell/quick_open/typed_command.dart': 'typed commands',
      'lib/src/features/explorer/application/explorer_tree_provider.dart':
          'explorer search projects',
      'lib/src/features/sessions/presentation/filter_menu_field.dart':
          'project, checkout and branch filter menus',
      'lib/src/features/settings/presentation/settings_catalog.dart':
          'settings search',
      'lib/src/features/settings/presentation/keyboard_section.dart': 'keymap',
      'lib/src/features/settings/presentation/acp_registry_picker.dart':
          'agent registry',
      'lib/src/features/stores/presentation/store_combine.dart': 'store apps',
      'lib/src/app/shell/logs_tab_view.dart': 'logs tab filter',
      '../packages/karmashala_ui/lib/src/file_browser_controller.dart':
          'file browser filter',
      '../packages/karmashala_core/lib/src/apps/installed_application.dart':
          'applications',
      '../server/lib/src/mcp/tools/inventory_tool_set.dart':
          'MCP list_sessions query',
    };
    final all = sources();
    final shared = RegExp(r'\b(matchesSearch|matchesSearchAny|searchMatch)\(');
    for (final MapEntry(key: path, value: what) in searches.entries) {
      expect(all[path], isNotNull, reason: '$path is gone; update the list');
      expect(
        shared.hasMatch(all[path]!),
        isTrue,
        reason: '$what ($path) does not use the shared matcher',
      );
    }
  });
}
