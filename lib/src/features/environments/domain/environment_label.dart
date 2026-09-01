import 'environment_kind.dart';
import 'execution_environment.dart';

/// How an execution environment is named wherever a user has to tell two of
/// them apart — the desktop's New project dropdown, and the environment each
/// checkout is reported to the phone under.
///
/// One function rather than one per surface: a phone that reads
/// `WSL · Ubuntu` and a desktop that says `Ubuntu` for the same machine would
/// be two vocabularies for one thing, and the phone's owner cannot check which
/// is which from where they are standing.
///
/// Exhaustive over [EnvironmentKind] on purpose, so a fourth kind is a compile
/// error rather than another mislabelled row. (The dropdown once offered an
/// SSH host as `WSL · build-box`.)
///
/// **Null means "nothing worth showing"** — an SSH row saved with a blank
/// name, a WSL row whose distribution was never recorded. Callers fall back to
/// the path, which at least locates the thing, rather than printing `SSH · `
/// or an empty line at the user.
String? environmentLabel(ExecutionEnvironment environment) =>
    switch (environment.kind) {
      // Every Windows-native environment is the one Windows, and "Windows" is
      // what its owner calls it — the row's stored name adds nothing.
      EnvironmentKind.windowsNative => 'Windows',
      EnvironmentKind.wsl => _qualified('WSL', [
        environment.wslDistribution,
        environment.name,
      ]),
      EnvironmentKind.ssh => _qualified('SSH', [environment.name]),
    };

/// `kind · <first candidate that says something>`, or null when none does.
String? _qualified(String kind, List<String?> candidates) {
  for (final candidate in candidates) {
    final name = candidate?.trim() ?? '';
    if (name.isNotEmpty) return '$kind · $name';
  }
  return null;
}

/// [label] as a screen reader should hear it.
///
/// The interpunct is a visual separator; spoken, it is either silence or the
/// words "middle dot". A comma is the pause the eye already reads it as.
String spokenEnvironmentLabel(String label) => label.replaceAll(' · ', ', ');
