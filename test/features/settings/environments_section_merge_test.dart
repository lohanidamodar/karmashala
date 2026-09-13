import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/settings/presentation/settings_nav.dart';

/// **SSH hosts live with the environments they are.**
///
/// `SshHostsController` saves a new host *and its `ssh:<id>` execution
/// environment* — one concept, which Settings showed on two pages. Folding the
/// SSH page in removes the duplicate; the keywords it answered to have to come
/// with it, or a search for "known hosts" lands nowhere.
void main() {
  test('there is no separate SSH section any more', () {
    expect(
      SettingsSectionId.values.map((s) => s.name),
      isNot(contains('ssh')),
    );
  });

  test('environments answers to what the SSH page answered to', () {
    final keywords = SettingsSectionId.environments.keywords;

    for (final term in ['ssh', 'hosts', 'known hosts', 'keys', 'remote build']) {
      expect(keywords, contains(term), reason: '"$term" found the SSH page');
    }
  });

  test('and still answers to its own', () {
    final keywords = SettingsSectionId.environments.keywords;

    for (final term in ['wsl', 'windows', 'flutter sdk']) {
      expect(keywords, contains(term), reason: term);
    }
  });
}
