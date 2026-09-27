/// The variable that says, whatever else is true, whether this server's
/// machine has a desktop: `1` for none (headless), `0` for one.
const String kHeadlessVariable = 'KARMASHALA_HEADLESS';

/// Whether a window can open on the server's machine — a browser to click
/// in, a desktop Flutter app to look at. A Linux box with no `DISPLAY` or
/// `WAYLAND_DISPLAY` (a droplet, a container) has none; macOS and Windows
/// are taken to have one. [kHeadlessVariable] overrides either way.
bool hasGuiSession(
  Map<String, String> environment, {
  required String operatingSystem,
}) {
  switch (environment[kHeadlessVariable]?.trim()) {
    case '1' || 'true':
      return false;
    case '0' || 'false':
      return true;
  }
  if (operatingSystem != 'linux') return true;
  bool set(String name) => (environment[name] ?? '').trim().isNotEmpty;
  return set('DISPLAY') || set('WAYLAND_DISPLAY');
}
