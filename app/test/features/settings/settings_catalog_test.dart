import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/presentation/settings_catalog.dart';
import 'package:karmashala_browser/browser.dart' show kBrowserConsentLocation;

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

    test('finds the continue of cut-off turns by how a person says it', () {
      const label = 'Continue turns cut off when the session host stops';
      for (final query in ['restart', 'crash', 'continue', 'cut off']) {
        expect(labels(query), contains(label), reason: query);
      }
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

    test('finds the side panel checklist by what VS Code calls it', () {
      for (final query in ['activity bar', 'rail', 'hide', 'side panel']) {
        expect(
          labels(query),
          contains('Tools in the More menu'),
          reason: query,
        );
      }
      expect(
        searchSettings('activity bar').single.page,
        SettingsSectionId.appearance,
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
    expect(SettingsSectionId.permissions.matches('browser consent'), isTrue);
    // Spec §6 merged Permissions into Tools and reach: one page, so the
    // consent is found there and nowhere else.
    expect(SettingsSectionId.permissions, SettingsSectionId.tools);
    expect(
      SettingsSectionId.values.where((p) => p.matches('browser consent')),
      [SettingsSectionId.tools],
    );
  });

  test('browser consent sits with the permissions, where its refusals send '
      'people', () {
    expect(SettingsAnchor.browser.page, SettingsSectionId.permissions);
    expect(
      kBrowserConsentLocation,
      'Settings → ${SettingsAnchor.browser.page.label} → '
      '${SettingsAnchor.browser.title}',
    );
  });

  test('automations are agent runs, filed with the agents after the '
      'permissions they run under', () {
    final agents = SettingsGroup.agents.pages;
    expect(SettingsSectionId.automations.group, SettingsGroup.agents);
    expect(
      agents.indexOf(SettingsSectionId.automations),
      agents.indexOf(SettingsSectionId.permissions) + 1,
    );
  });

  test('device slimming has a page, beside Projects, that search finds', () {
    expect(SettingsSectionId.devices.group, SettingsGroup.workspace);
    final workspace = SettingsGroup.workspace.pages;
    expect(
      workspace.indexOf(SettingsSectionId.devices),
      workspace.indexOf(SettingsSectionId.projects) + 1,
    );
    for (final term in ['emulator', 'simulator', 'slimming', 'gpu', 'avd']) {
      expect(
        SettingsSectionId.values.where((p) => p.matches(term)),
        contains(SettingsSectionId.devices),
        reason: term,
      );
    }
    expect(
      searchSettings('renderer').map((e) => e.anchor),
      contains(SettingsAnchor.androidEmulators),
    );
    expect(
      searchSettings('universal links').single.anchor,
      SettingsAnchor.iosSimulators,
    );
  });

  test('the SSH relay and phone pairing are found by the words people use', () {
    for (final query in ['relay', 'ssh relay']) {
      expect(
        searchSettings(query).map((e) => e.label),
        contains('Use an SSH host as a relay'),
        reason: query,
      );
    }
    for (final query in ['pair phone', 'qr']) {
      final hit = searchSettings(
        query,
      ).firstWhere((e) => e.label == 'Pair a phone with an SSH host');
      // It lives where the machine is: the SSH host's card, on Environments.
      expect(hit.anchor, SettingsAnchor.sshHosts, reason: query);
    }
  });

  test('a link naming the page a section used to be on still lands on it', () {
    final target = SettingsTarget(
      SettingsSectionId.tools,
      anchor: SettingsAnchor.browser,
    );
    expect(target.page, SettingsSectionId.permissions);
    expect(target.anchor, SettingsAnchor.browser);
  });
}
