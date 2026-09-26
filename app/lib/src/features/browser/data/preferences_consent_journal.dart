import 'package:karmashala_data_protocol/karmashala_data_protocol.dart'
    show PreferenceStore;
import 'package:karmashala_browser/browser.dart';

/// Browser consent grants among the preferences — deliberately
/// *not* inside `Settings`, which is copied and written wholesale.
class PreferencesConsentJournal implements ConsentJournal {
  const PreferencesConsentJournal(this._preferences);

  final PreferenceStore _preferences;

  @override
  String? read(String key) => _preferences.read(key);

  @override
  void write(String key, String value) => _preferences.write(key, value);
}
