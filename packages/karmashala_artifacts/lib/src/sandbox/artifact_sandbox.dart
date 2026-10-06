import 'dart:convert';

/// The page an HTML artifact is shown in. The web view loads this fixed shell,
/// never the artifact itself: the artifact runs in an `allow-scripts`-only
/// iframe, so its origin is opaque — no reach into the shell, storage or
/// cookies, no top navigation, no popups — and inherits the shell's policy,
/// which loads nothing from the network (https only when [allowNetwork]) and
/// nothing from a file.
String artifactSandboxShell(String html, {required bool allowNetwork}) {
  final policy = allowNetwork ? _networkPolicy : _offlinePolicy;
  final srcdoc = const HtmlEscape(HtmlEscapeMode.attribute).convert(html);
  return '<!doctype html>'
      '<html><head>'
      '<meta http-equiv="Content-Security-Policy" content="$policy">'
      '<meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width,initial-scale=1">'
      '<style>html,body{margin:0;height:100%;background:#fff}'
      'iframe{border:0;width:100%;height:100%;display:block}</style>'
      '</head><body>'
      '<iframe sandbox="allow-scripts" referrerpolicy="no-referrer" '
      'srcdoc="$srcdoc"></iframe>'
      '</body></html>';
}

const _offlinePolicy =
    "default-src 'none'; "
    "script-src 'unsafe-inline' 'unsafe-eval'; "
    "style-src 'unsafe-inline'; "
    'img-src data: blob:; '
    'font-src data:; '
    'media-src data: blob:; '
    "connect-src 'none'; "
    "frame-src 'none'; "
    "form-action 'none'; "
    "base-uri 'none'";

const _networkPolicy =
    "default-src 'none'; "
    "script-src 'unsafe-inline' 'unsafe-eval' https:; "
    "style-src 'unsafe-inline' https:; "
    'img-src data: blob: https:; '
    'font-src data: https:; '
    'media-src data: blob: https:; '
    'connect-src https:; '
    "frame-src 'none'; "
    "form-action 'none'; "
    "base-uri 'none'";

/// Whether the web view may load [uri]: the shell and its srcdoc frame, and
/// nothing else — a link, a redirect or a script's `location =` is refused,
/// with the network allowed or not.
bool artifactSandboxAllowsNavigation(Uri uri) =>
    uri.scheme == 'about' && (uri.path == 'blank' || uri.path == 'srcdoc');

/// What the web view is set up with. Held as a value so a test can see the
/// sandbox is offered nothing: no JavaScript handlers (Karmashala's bridge),
/// no file or content access, no extra windows, no inspector.
class ArtifactSandboxSettings {
  const ArtifactSandboxSettings({
    required this.javaScriptHandlers,
    required this.allowFileAccess,
    required this.allowFileAccessFromFileUrls,
    required this.allowUniversalAccessFromFileUrls,
    required this.allowContentAccess,
    required this.multipleWindows,
    required this.inspectable,
    required this.incognito,
  });

  final List<String> javaScriptHandlers;
  final bool allowFileAccess;
  final bool allowFileAccessFromFileUrls;
  final bool allowUniversalAccessFromFileUrls;
  final bool allowContentAccess;
  final bool multipleWindows;
  final bool inspectable;
  final bool incognito;
}

const kArtifactSandboxSettings = ArtifactSandboxSettings(
  javaScriptHandlers: [],
  allowFileAccess: false,
  allowFileAccessFromFileUrls: false,
  allowUniversalAccessFromFileUrls: false,
  allowContentAccess: false,
  multipleWindows: false,
  inspectable: false,
  incognito: true,
);
