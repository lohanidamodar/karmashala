import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/terminal/data/prompt_typer.dart';

/// `testWidgets` for its fake clock: `pump(duration)` is the quiet spell.
void main() {
  testWidgets('text waits for the shell to paint and go quiet, then is typed '
      'once', (tester) async {
    final sent = <String>[];
    final typer = PromptTyper(send: sent.add);
    addTearDown(typer.dispose);

    typer.type('sudo ufw allow 8787/tcp');
    await tester.pump(const Duration(seconds: 5));
    expect(sent, isEmpty, reason: 'nothing is connected yet');

    // A login banner, then the prompt, each restarting the quiet spell.
    typer.onOutput();
    await tester.pump(const Duration(milliseconds: 300));
    typer.onOutput();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sent, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));

    expect(sent, ['sudo ufw allow 8787/tcp']);
    typer.onOutput();
    await tester.pump(const Duration(seconds: 1));
    expect(sent, hasLength(1), reason: 'typed once, never again');
  });

  testWidgets('it can never press Enter: no CR, LF or control byte survives', (
    tester,
  ) async {
    expect(
      unsubmittable('sudo ufw allow 1/tcp\r\nrm -rf ~\n'),
      'sudo ufw allow 1/tcp rm -rf ~',
    );
    expect(unsubmittable('a\x03b\x1b[Ac\x7f'), 'ab[Ac');
    expect(unsubmittable('  spaced  '), 'spaced');

    final sent = <String>[];
    final typer = PromptTyper(send: sent.add)
      ..type('echo hi\r')
      ..onOutput();
    addTearDown(typer.dispose);
    await tester.pump(const Duration(seconds: 1));

    expect(sent.single, 'echo hi');
    expect(sent.single, isNot(anyOf(contains('\r'), contains('\n'))));
  });

  testWidgets('a shell already at its prompt is typed at straight away', (
    tester,
  ) async {
    final sent = <String>[];
    final typer = PromptTyper(send: sent.add)..onOutput();
    addTearDown(typer.dispose);
    await tester.pump(const Duration(seconds: 2));

    typer.type('uptime');
    await tester.pump(const Duration(milliseconds: 500));

    expect(sent, ['uptime']);
  });

  testWidgets('a pane closed before its prompt types nothing', (tester) async {
    final sent = <String>[];
    final typer = PromptTyper(send: sent.add)
      ..type('uptime')
      ..onOutput();
    typer.dispose();
    await tester.pump(const Duration(seconds: 1));

    expect(sent, isEmpty);
  });
}
