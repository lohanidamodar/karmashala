/// The theme preference: follow the OS, or force light/dark.
enum AppThemeMode {
  system('System'),
  light('Light'),
  dark('Dark');

  const AppThemeMode(this.label);
  final String label;
}
