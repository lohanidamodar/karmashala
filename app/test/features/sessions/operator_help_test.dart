import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/sessions/presentation/operator_chip.dart';
import 'package:karmashala_mcp/catalogue.dart';

/// The Operate Karmashala switch's help: what a session already does without
/// it, where the server keeps tool access.
void main() {
  test('an older server keeps the grant\'s own words', () {
    expect(operatorNotGrantedHelp(null), kOperatorNotGrantedHelp);
  });

  test('names the groups open to the session, and where to change them', () {
    final text = operatorNotGrantedHelp(
      McpToolAccessPolicy.defaults.groupsOpen(),
    );
    expect(text, contains('only Message sessions and Start sessions'));
    expect(text, contains(kMcpToolAccessLocation));
    expect(text, contains('not a sandbox'));
  });

  test('one group, and none', () {
    expect(
      operatorNotGrantedHelp(const [McpToolGroup.start]),
      contains('only Start sessions ('),
    );
    expect(
      operatorNotGrantedHelp(const []),
      contains('none of the tool groups'),
    );
  });
}
