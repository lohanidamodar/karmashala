import 'dart:convert';

/// The page an HTML artifact runs in when a person opens it in their browser:
/// a fixed shell holding the artifact in an `allow-scripts`-only iframe, so
/// its origin is opaque — no reach into the shell, storage or cookies, no top
/// navigation, no popups — under the shell's policy, which loads nothing from
/// the network (https only when [allowNetwork]) and nothing from a file.
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

