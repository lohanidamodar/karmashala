import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';

/// The catalogue the rail, search, page layout and deep links all read. A
/// page nobody can land on, a section with nothing searchable in it, or an old
/// search term that now finds nothing are regressions, not tidiness.
void main() {
  test('every group has pages and every page has sections', () {
    for (final group in SettingsGroup.values) {
      expect(group.pages, isNotEmpty, reason: '${group.label} is empty');
    }
    for (final page in SettingsSectionId.values) {
      expect(page.anchors, isNotEmpty, reason: '${page.label} has no section');
      expect(page.description, isNotEmpty, reason: page.label);
    }
  });

  test('the rail runs group by group, in declaration order', () {
    final grouped = [for (final group in SettingsGroup.values) ...group.pages];
    expect(grouped, SettingsSectionId.values);
  });

  test('every section has at least one option a search can find', () {
    for (final anchor in SettingsAnchor.values) {
      expect(
        settingsEntries.where((e) => e.anchor == anchor),
        isNotEmpty,
        reason: '${anchor.page.label} › ${anchor.title} has no entry',
      );
    }
  });

  test('labels are not repeated where they would be ambiguous', () {
    final pageLabels = SettingsSectionId.values.map((p) => p.label).toList();
    expect(pageLabels.toSet(), hasLength(pageLabels.length));
    final entryLabels = settingsEntries.map((e) => e.label).toList();
    expect(entryLabels.toSet(), hasLength(entryLabels.length));
    for (final page in SettingsSectionId.values) {
      final titles = page.anchors.map((a) => a.title).toList();
      expect(titles.toSet(), hasLength(titles.length), reason: page.label);
    }
  });

  test('keywords are lower-case, so a match is case-blind', () {
    for (final anchor in SettingsAnchor.values) {
      for (final k in anchor.keywords) {
        expect(k, k.toLowerCase(), reason: anchor.name);
      }
    }
    for (final entry in settingsEntries) {
      for (final k in entry.keywords) {
        expect(k, k.toLowerCase(), reason: entry.label);
      }
    }
  });

  group('search', () {
    List<String> labels(String query) =>
        searchSettings(query).map((e) => e.label).toList();

    test('finds an option by its label, in any case', () {
      expect(labels('close to TRAY'), contains('Close to tray'));
    });

    test('finds an option by what its description says', () {
      expect(labels('system tray'), contains('Close to tray'));
      expect(
        labels('crash or a restart'),
        contains('Run local terminals in the session host'),
      );
    });

    test('finds an option by a word that is on neither', () {
      expect(labels('dotfiles'), ['Show hidden files']);
      expect(labels('quota'), ['Usage & limits']);
    });

    test('an empty query finds nothing, and nonsense finds nothing', () {
      expect(searchSettings('  '), isEmpty);
      expect(searchSettings('zzqxv'), isEmpty);
      expect(
        SettingsSectionId.values.where((p) => p.matches('zzqxv')),
        isEmpty,
      );
    });

    test('a hit names the page the rail shows it under', () {
      final hit = searchSettings('dotfiles').single;
      expect(hit.page, SettingsSectionId.editorFiles);
      expect(hit.anchor, SettingsAnchor.fileBrowsing);
    });
  });

  test('every word the old rail answered to still finds a page', () {
    // The keyword lists the fourteen-page rail carried before the catalogue,
    // copied from it: moving an option must not strand the search for it.
    const old = [
      'theme',
      'dark',
      'light',
      'text size',
      'zoom',
      'scale',
      'density',
      'compact',
      'tray',
      'startup',
      'start at login',
      'keep awake',
      'sleep',
      'hotkey',
      'launcher',
      'shell',
      'font',
      'size',
      'colors',
      'chords',
      'keys',
      'integration',
      'snippet',
      'command',
      'saved command',
      'library',
      'editor',
      'vs code',
      'terminal app',
      'resume',
      'mcp',
      'bridge',
      'agent tools',
      'tool list',
      'browser consent',
      'app projects',
      'flutter',
      'react native',
      'build',
      'default agent',
      'default model',
      'model',
      'opus',
      'sonnet',
      'claude',
      'codex',
      'accounts',
      'usage',
      'limits',
      'ask',
      'bypass',
      'accept edits',
      'sessions',
      'automation',
      'schedule',
      'cron',
      'nightly',
      'unattended',
      'afk',
      'project check',
      'verification',
      'worktree',
      'post create',
      'pub get',
      'gitignored',
      'dart_tool',
      'node_modules',
      'wsl',
      'windows',
      'discover',
      'installations',
      'flutter sdk',
      'sdk',
      'dart',
      'ssh',
      'hosts',
      'known hosts',
      'remote build',
      'env',
      'env var',
      'environment variable',
      'secret',
      'token',
      'api key',
      'credential',
      'companion',
      'phone',
      'pairing',
      'relay',
      'devices',
      'note',
      'idea',
      'save for later',
      'logs',
      'log file',
      'debug',
      'debug mode',
      'verbose',
      'troubleshoot',
      'report',
    ];
    for (final term in old) {
      expect(
        SettingsSectionId.values.where((p) => p.matches(term)),
        isNotEmpty,
        reason: '"$term" found a page before',
      );
    }
  });

  test('where the moved options now live', () {
    expect(SettingsSectionId.general.matches('notes'), isTrue);
    expect(SettingsSectionId.editorFiles.matches('word wrap'), isTrue);
    expect(SettingsSectionId.editorFiles.matches('file picker'), isTrue);
    expect(SettingsSectionId.projects.matches('worktree'), isTrue);
    expect(SettingsSectionId.accounts.matches('usage'), isTrue);
    expect(SettingsSectionId.tools.matches('browser consent'), isTrue);
  });
}
