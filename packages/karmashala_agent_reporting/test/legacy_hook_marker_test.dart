import 'package:karmashala_core/util.dart';
import 'package:karmashala_agent_reporting/hooks.dart';
import 'package:test/test.dart';

/// The strings this app wrote into *other programs'* config files under names
/// it no longer uses.
///
/// An entry is identified only by its marker, and Antigravity's whole block is
/// held under a key that is the app's own name. So a rename that forgets them
/// does not move those entries — it strands them: the new build does not
/// recognise them, and the old build has been uninstalled and cannot be asked.
/// Nothing else in the system can find them again.
///
/// This file exists because the danger is a *find-and-replace*. These literals
/// are the one place in the codebase where the old name must survive one, and
/// a blanket rename would quietly rewrite them along with everything else.
void main() {
  group('markers and keys from former names', () {
    test('each is a literal that no longer matches the current name', () {
      for (final marker in legacyAgentHookMarkers) {
        expect(
          marker,
          isNot(contains(agentHookMarker)),
          reason:
              'a "legacy" marker equal to the current one has been rewritten '
              'by a rename — it can no longer find what it exists to remove',
        );
      }
    });

    test('a hook written under an old marker is still recognised as ours', () {
      // The whole point: uninstall and reinstall both find it.
      const installer = AgentHookInstaller();
      for (final marker in legacyAgentHookMarkers) {
        final entry = {
          'hooks': [
            {
              'type': 'command',
              'command': 'curl -s "http://x/?marker=$marker"',
            },
          ],
        };
        expect(
          installer.debugIsOurs(entry),
          isTrue,
          reason: 'an entry carrying $marker is ours and must be removable',
        );
      }
    });
  });

  group('removeTopLevelJsonKey', () {
    test('removes ours and leaves every sibling byte-intact', () {
      const raw = '{"other": {"a": 1}, "karmashala": {"Stop": []}, "z": 2}';
      expect(
        removeTopLevelJsonKey(raw, 'karmashala'),
        '{"other": {"a": 1}, "z": 2}',
      );
    });

    test('handles ours being first, last, and only', () {
      expect(removeTopLevelJsonKey('{"ours": 1, "b": 2}', 'ours'), '{"b": 2}');
      expect(removeTopLevelJsonKey('{"b": 2, "ours": 1}', 'ours'), '{"b": 2}');
      expect(removeTopLevelJsonKey('{"ours": 1}', 'ours'), '{}');
    });

    test('a key that is not there changes nothing at all', () {
      const raw = '{"a": 1,   "b":   [2,3]}';
      expect(removeTopLevelJsonKey(raw, 'nope'), raw);
    });

    test('keys differing only by case are not confused', () {
      // The reason this file splices rather than round-trips.
      const raw = '{"g:/x": 1, "G:/x": 2}';
      expect(removeTopLevelJsonKey(raw, 'g:/x'), '{"G:/x": 2}');
    });
  });
}
