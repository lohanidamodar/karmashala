import 'package:test/test.dart';
import 'package:karmashala_artifacts/karmashala_artifacts.dart';

/// An HTML artifact is untrusted: it runs in an opaque-origin iframe inside a
/// fixed shell whose policy refuses the network (until allowed), every file,
/// every navigation away and every popup — and no bridge is offered to it.
void main() {
  String cspOf(String shell) =>
      RegExp(r'content="([^"]*)"').firstMatch(shell)![1]!;

  test('the shell is a fixed page holding the artifact in a sandbox', () {
    final shell = artifactSandboxShell('<h1>Hi</h1>', allowNetwork: false);
    expect(shell, startsWith('<!doctype html>'));
    final iframe = RegExp(r'<iframe[^>]*>').firstMatch(shell)![0]!;
    expect(iframe, contains('sandbox="allow-scripts"'));
    for (final token in [
      'allow-same-origin',
      'allow-top-navigation',
      'allow-popups',
      'allow-forms',
      'allow-modals',
      'allow-downloads',
    ]) {
      expect(iframe, isNot(contains(token)), reason: token);
    }
  });

  test('network off: the policy loads nothing from anywhere', () {
    final csp = cspOf(artifactSandboxShell('x', allowNetwork: false));
    expect(csp, contains("default-src 'none'"));
    expect(csp, contains("frame-src 'none'"));
    expect(csp, contains("connect-src 'none'"));
    expect(csp, isNot(contains('http')));
    expect(csp, isNot(contains('file:')));
    expect(csp, isNot(contains('*')));
  });

  test('network allowed: https only, still no file and no framing', () {
    final csp = cspOf(artifactSandboxShell('x', allowNetwork: true));
    expect(csp, contains('connect-src https:'));
    expect(csp, contains('script-src'));
    expect(csp, contains("frame-src 'none'"));
    expect(csp, isNot(contains('file:')));
    expect(csp, isNot(contains('http:')));
  });

  test('the policy is the first thing in the head', () {
    final shell = artifactSandboxShell('x', allowNetwork: false);
    final head = shell.indexOf('<head>');
    final meta = shell.indexOf('Content-Security-Policy');
    final firstTagAfterHead = shell.indexOf('<', head + 1);
    expect(firstTagAfterHead, lessThan(meta));
    expect(shell.substring(head, meta), isNot(contains('<script')));
  });

  test('the artifact cannot break out of srcdoc', () {
    const hostile = '"></iframe><script>parent.document.body.innerHTML=1'
        '</script><iframe srcdoc="&amp;';
    final shell = artifactSandboxShell(hostile, allowNetwork: false);
    expect(RegExp('<iframe').allMatches(shell), hasLength(1));
    expect(RegExp('<script').allMatches(shell), isEmpty);
    expect(shell, contains('&quot;&gt;&lt;/iframe&gt;'));
    expect(shell, contains('&amp;amp;'));
  });

  test('only the shell itself may load; everything else is refused', () {
    expect(artifactSandboxAllowsNavigation(Uri.parse('about:blank')), isTrue);
    expect(artifactSandboxAllowsNavigation(Uri.parse('about:srcdoc')), isTrue);
    for (final url in [
      'https://example.com/',
      'http://localhost:8080/',
      'file:///C:/Users/x/.ssh/id_rsa',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'karmashala://bridge',
      'data:text/html,<p>x',
      'blob:null/abc',
    ]) {
      expect(
        artifactSandboxAllowsNavigation(Uri.parse(url)),
        isFalse,
        reason: url,
      );
    }
  });

  test('the web view is offered no bridge, no files and no windows', () {
    const s = kArtifactSandboxSettings;
    expect(s.javaScriptHandlers, isEmpty);
    expect(s.allowFileAccess, isFalse);
    expect(s.allowFileAccessFromFileUrls, isFalse);
    expect(s.allowUniversalAccessFromFileUrls, isFalse);
    expect(s.allowContentAccess, isFalse);
    expect(s.multipleWindows, isFalse);
    expect(s.inspectable, isFalse);
    expect(s.incognito, isTrue);
  });
}
