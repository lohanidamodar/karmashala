import 'dart:convert';

import 'package:karmashala_host/mcp_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala_mcp/catalogue.dart';

/// Arming an automation is a human action in the UI and nowhere else.
///
/// Exposing create / run / pause / delete to an agent lets an agent schedule an
/// agent, which is the line the re-opened invariant still forbids: *nothing
/// starts an agent the user did not authorise*. An automation **is** that
/// authorisation, given in advance by a person; a tool that could arm one would
/// be the same act with the person taken out of it.
///
/// An agent may only **propose** one: saved off, marked as its proposal, for
/// the owner to turn on (2026-10-07). The server's own test proves a proposal
/// is stored off whatever it asks; this one holds the served surface to it.
///
/// A test rather than a comment because the failure mode is somebody adding
/// `automation_list` next year for the best of reasons, and a rule nothing
/// checks is a rule that has already been broken once.
void main() {
  final servedNames = <String>{
    for (final schema in serverToolSchemas) schema['name']! as String,
  };
  Map<String, Object?> schemaOf(String name) =>
      serverToolSchemas.firstWhere((s) => s['name'] == name);

  test('no served tool belongs to the automation family but a propose-only '
      'one', () {
    final offenders = servedNames
        .where((name) => name.toLowerCase().startsWith('automation'))
        .where((name) => !kProposeOnlyAutomationTools.contains(name))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason:
          'arming, running, pausing or deleting an automation from a tool lets '
          'an agent schedule an agent. It is a human action in the UI '
          '(the Automations tab) and nowhere else; an agent only proposes.',
    );
    expect(kProposeOnlyAutomationTools, everyElement(isIn(servedNames)));
  });

  test(
    'a propose-only tool cannot ask to enable, arm, run or keep a secret',
    () {
      for (final name in kProposeOnlyAutomationTools) {
        final schema = schemaOf(name);
        final properties =
            ((schema['inputSchema']! as Map)['properties']! as Map).keys
                .cast<String>();
        for (final word in ['enable', 'arm', 'run', 'secret', 'active']) {
          expect(
            properties.where((p) => p.toLowerCase().contains(word)),
            isEmpty,
            reason:
                '$name takes no "$word" argument: only a person turns it on',
          );
        }
        final said = (schema['description']! as String).toLowerCase();
        expect(said, contains('owner'), reason: name);
        expect(said, contains('turn'), reason: name);
      }
    },
  );

  test('the annotation table names no other of them either', () {
    // Belt and braces: the table and the served set are already held equal by
    // `mcp_tool_catalogue_test.dart`, so a name appearing in one and not the
    // other is itself a failure — but a rule this cheap should be asserted at
    // both ends rather than inferred.
    expect(
      kMcpToolAnnotations.keys.where(
        (name) =>
            name.toLowerCase().startsWith('automation') &&
            !kProposeOnlyAutomationTools.contains(name),
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
    expect(servedNames.where((name) => name.contains('cron')), isEmpty);
    // A proposal answers no secret: none is in what the tools describe.
    expect(
      jsonEncode([
        for (final name in kProposeOnlyAutomationTools) schemaOf(name),
      ]).toLowerCase(),
      isNot(contains('only time the secret is shown')),
    );
  });
}
