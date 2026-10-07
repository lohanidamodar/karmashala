import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every workbench page tab wears one header: `WorkbenchTabScaffold`. An
/// `AppBar(` is allowed only on a pushed route — a page with a back arrow —
/// never on a tab, where a hand-built copy drifts from the Stores header.
void main() {
  final appBar = RegExp(r'(?<![\w$])AppBar\(');

  /// Routes pushed over the shell, each with a back arrow: not tabs.
  const routes = {
    'lib/src/app/shell/phone_more_page.dart': 'More and its pages',
    'lib/src/app/shell/phone_shell.dart': 'the phone shell',
    'lib/src/app/shell/phone_top_bar.dart': 'the phone top bar',
    'lib/src/app/widgets/full_screen_form.dart': 'a full-screen form',
    'lib/src/features/artifacts/presentation/artifact_screen.dart': 'artifact',
    'lib/src/features/remote/presentation/pair_machine_forms.dart': 'pairing',
    'lib/src/features/remote/presentation/pair_machine_page.dart': 'pairing',
    'lib/src/features/remote/presentation/pair_machine_scan.dart': 'pairing',
    '../packages/karmashala_ui/lib/src/file_browser.dart': 'a folder picker',
    '../packages/karmashala_ui/lib/src/workbench_tab_scaffold.dart':
        'the shared header itself',
  };

  /// Rounds 33 and 34 are rewriting these; the parent moves them onto the
  /// shared header at merge, and then this list empties.
  const pendingMigration = {
    'lib/src/features/overview/presentation/overview_tab_view.dart',
  };

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

  test('the guard sees a hand-built AppBar and nothing else', () {
    expect(appBar.hasMatch('appBar: AppBar(toolbarHeight: 44)'), isTrue);
    expect(appBar.hasMatch('SliverAppBar('), isFalse);
    expect(appBar.hasMatch('appBar: null'), isFalse);
  });

  test('no workbench tab builds its own AppBar', () {
    final found = <String>[];
    sources().forEach((path, source) {
      if (routes.containsKey(path) || pendingMigration.contains(path)) return;
      for (final match in appBar.allMatches(source)) {
        final line = '\n'.allMatches(source.substring(0, match.start)).length;
        found.add('$path:${line + 1}');
      }
    });
    expect(
      found,
      isEmpty,
      reason:
          'a tab wears WorkbenchTabScaffold from karmashala_ui; a pushed '
          'route with a back arrow goes in `routes` here',
    );
  });

  test('the tabs moved in round 36 use the shared header', () {
    const tabs = [
      'lib/src/features/stores/presentation/stores_tab_view.dart',
      'lib/src/features/agents/presentation/usage_tab/usage_tab_view.dart',
      'lib/src/app/shell/logs_tab_view.dart',
      'lib/src/app/shell/phone_log_page.dart',
    ];
    final all = sources();
    for (final path in tabs) {
      expect(all[path], contains('WorkbenchTabScaffold('), reason: path);
    }
  });
}
