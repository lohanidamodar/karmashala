import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/mcp/launcher_control_server.dart';
import 'package:karmashala/src/features/mcp/mcp_tool_catalogue.dart';

/// Arming an automation is a human action in the UI and nowhere else.
///
/// Exposing create / run / pause / delete to an agent lets an agent schedule an
/// agent, which is the line the re-opened invariant still forbids: *nothing
/// starts an agent the user did not authorise*. An automation **is** that
/// authorisation, given in advance by a person; a tool that could arm one would
/// be the same act with the person taken out of it.
///
/// A test rather than a comment because the failure mode is somebody adding
/// `automation_list` next year for the best of reasons, and a rule nothing
/// checks is a rule that has already been broken once.
void main() {
  final servedNames = <String>{
    for (final schema in LauncherControlServer.toolSchemas)
      schema['name']! as String,
  };

  test('no served tool belongs to the automation family', () {
    final offenders = servedNames
        .where((name) => name.toLowerCase().startsWith('automation'))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason:
          'arming, running, pausing or deleting an automation from a tool lets '
          'an agent schedule an agent. It is a human action in the UI '
          '(Settings → Automations) and nowhere else.',
    );
  });

  test('the annotation table names none of them either', () {
    // Belt and braces: the table and the served set are already held equal by
    // `mcp_tool_catalogue_test.dart`, so a name appearing in one and not the
    // other is itself a failure — but a rule this cheap should be asserted at
    // both ends rather than inferred.
    expect(
      kMcpToolAnnotations.keys.where(
        (name) => name.toLowerCase().startsWith('automation'),
      ),
      isEmpty,
    );
  });

  test('the rule is stated where the four hints are, not only here', () {
    // The catalogue's own doc carries it. Asserting the sentence would pin
    // prose; asserting that the *family* is absent from both surfaces is the
    // part that can regress.
    expect(
      servedNames.where((name) => name.contains('schedule')),
      isEmpty,
      reason: 'no scheduling surface is served to an agent under any name',
    );
    expect(
      servedNames.where((name) => name.contains('cron')),
      isEmpty,
    );
  });
}
