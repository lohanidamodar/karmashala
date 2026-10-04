import 'dart:convert';

import 'package:karmashala_remote/remote.dart';
import 'package:test/test.dart';

/// `approval.requested` carries an ACP agent's own options, additively: an
/// older payload reads as none, and each option says whether it allows.
void main() {
  Map<String, Object?> wire(Object? json) =>
      (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

  test('the options cross the wire whole, in order', () {
    const request = RemoteApprovalRequest(
      sessionId: 's1',
      waiting: RemoteWaitKind.approval,
      approveLabel: 'Allow',
      denyLabel: 'Reject',
      options: [
        RemoteApprovalOption(id: 'allow', name: 'Allow', kind: 'allow_once'),
        RemoteApprovalOption(
          id: 'allow-always',
          name: 'Always allow',
          kind: 'allow_always',
        ),
        RemoteApprovalOption(
          id: 'reject-always',
          name: 'Never',
          kind: 'reject_always',
        ),
      ],
    );
    final read = RemoteApprovalRequest.fromJson(wire(request.toJson()));
    expect(read.options, request.options);
    expect(read.options.map((o) => o.allows), [true, true, false]);
  });

  test('a host that sends none, or an older one, reads as none', () {
    const plain = RemoteApprovalRequest(sessionId: 's1');
    expect(plain.toJson().containsKey('options'), isFalse);
    expect(RemoteApprovalRequest.fromJson(wire(plain.toJson())).options, isEmpty);
    expect(
      RemoteApprovalRequest.fromJson({
        'sessionId': 's1',
        'options': [
          {'name': 'no id'},
          'junk',
        ],
      }).options,
      isEmpty,
    );
  });
}
