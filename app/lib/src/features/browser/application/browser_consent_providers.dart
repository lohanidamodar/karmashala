import 'package:riverpod/riverpod.dart';

import '../../../core/data/data_providers.dart';
import '../data/preferences_consent_journal.dart';
import 'package:karmashala_browser/browser.dart';

/// The recorded browser-consent grants, which a person gives and takes back
/// in Settings; the server reads them on every gated agent call.
final browserConsentStoreProvider = Provider<BrowserConsentStore>(
  (ref) => BrowserConsentStore(
    PreferencesConsentJournal(ref.watch(appPreferencesProvider)),
  ),
);

/// Bumped whenever a grant is made or taken back, so the settings list
/// redraws: the store reads the preference per call and holds no state.
final browserConsentRevisionProvider =
    NotifierProvider<BrowserConsentRevision, int>(BrowserConsentRevision.new);

class BrowserConsentRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}
