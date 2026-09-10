import 'package:karmashala_terminal_core/shell_integration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';

/// OSC 777 — measured, because a backlog item was written on the assumption
/// that it arrives.
///
/// The item ("OSC 777 `warp://cli-agent`") proposed reading typed agent events
/// out of the PTY on the grounds that "our vendored parser already delivers
/// private OSC to `onPrivateOSC`, so the cost is a parser branch and a
/// mapping". Both halves of that are wrong, and this is the half a test can
/// settle: **777 is not private in this parser.** `_handleOSC` claims it by
/// number and returns, so it never reaches `unknownOSC` and never reaches the
/// router the pane fans out from. `Terminal.showNotification` is where it
/// goes, and this app sets no `onNotification`, so today the sequence is
/// parsed and dropped.
///
/// The other half is not testable here and is recorded where it was found: no
/// CLI on this machine emits it. `warp://cli-agent` is printed by *Warp's own
/// Claude Code plugin*, whose hook scripts read the same hook payloads this app
/// already receives directly, and only when Warp has set
/// `WARP_CLI_AGENT_PROTOCOL_VERSION` and `WARP_CLIENT_VERSION` in the
/// environment. `strings` over claude 2.1.263, the Codex standalone build and
/// `agy` finds no `warp://` in any of them.
void main() {
  ({List<String> private, List<String> notifications}) writeToTerminal(
    String bytes,
  ) {
    final terminal = Terminal(maxLines: 100)..resize(80, 24);
    final router = OscRouter();
    final private = <String>[];
    final notifications = <String>[];
    router.add((code, args) => private.add('$code:${args.join(",")}'));
    terminal.onPrivateOSC = router.dispatch;
    // Braces, not an arrow: a cascade after an arrow body binds to the body.
    terminal.onNotification = (title, body) {
      notifications.add('$title|$body');
    };
    terminal.write(bytes);
    return (private: private, notifications: notifications);
  }

  test('the Warp payload is read as a notification, not as a private OSC', () {
    // The sequence Warp's plugin prints, in the shape `warp-notify.sh` builds
    // it: `printf '\033]777;notify;%s;%s\007' "$TITLE" "$BODY"`.
    const payload =
        '{"v":1,"agent":"claude","event":"stop","session_id":"abc",'
        '"cwd":"/src/app","project":"app"}';
    final seen = writeToTerminal(
      '\x1b]777;notify;warp://cli-agent;$payload\x07',
    );

    expect(
      seen.private,
      isEmpty,
      reason: 'the router the pane fans out from never sees OSC 777',
    );
    expect(seen.notifications, ['warp://cli-agent|$payload']);
  });

  test('a JSON body survives the parser splitting on semicolons', () {
    // The parameters arrive split on `;` and the body is rejoined from the
    // third onwards, so a `;` inside the JSON is not a data loss — worth
    // pinning, because a tool-input preview is exactly where one turns up.
    const payload = '{"summary":"Wants to run Bash: cd /x; ls"}';
    final seen = writeToTerminal(
      '\x1b]777;notify;warp://cli-agent;$payload\x07',
    );

    expect(seen.notifications, ['warp://cli-agent|$payload']);
  });

  test('no shape of OSC 777 reaches the router', () {
    // The parser claims the number, not the `notify` form: a short payload and
    // an unknown sub-command are both swallowed by the same `case`. So there
    // is no branch to add in `osc_router.dart`: a second in-band source would
    // have to come through `onNotification` or through the fork.
    for (final bytes in const [
      '\x1b]777;notify\x07',
      '\x1b]777;notify;only-a-title\x07',
      '\x1b]777;something-else;a;b\x07',
    ]) {
      expect(writeToTerminal(bytes).private, isEmpty, reason: bytes);
    }
  });

  test('a genuinely private OSC still arrives, so the fan-out works', () {
    // The control: OSC 133 is not claimed by number and does reach the router,
    // which is what makes the emptiness above a fact about 777 rather than
    // about this test's wiring.
    expect(writeToTerminal('\x1b]133;A\x07').private, ['133:A']);
  });
}
