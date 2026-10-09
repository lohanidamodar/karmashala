import 'package:agent_cli/process.dart';
import 'package:karmashala_session/session.dart';
import 'package:test/test.dart';

const _checkout = EnvironmentPath(environmentId: 'win', path: r'C:\src\app');

Session _session(
  String id, {
  SessionStatus status = SessionStatus.running,
  EnvironmentPath? workingDirectory = _checkout,
  String? mode,
  DateTime? archivedAt,
}) => Session(
  id: id,
  repositoryId: 'r1',
  agentInstallationId: 'a1',
  title: 'Session $id',
  useWorktree: false,
  status: status,
  createdAt: DateTime.utc(2026, 10, 9),
  workingDirectory: workingDirectory,
  permissionMode: mode,
  archivedAt: archivedAt,
);

/// The rule the dialog, the badge and `list_checkouts` share.
void main() {
  bool lower(String a, String b) => a.toLowerCase() == b.toLowerCase();

  List<String> writers(
    Iterable<Session> among, {
    String? excluding,
    Map<String, List<EnvironmentPath>> attached = const {},
  }) => [
    for (final s in sessionsWritingIn(
      _checkout,
      among: among,
      directoriesOf: (s) => [?s.workingDirectory, ...?attached[s.id]],
      pathsMatch: lower,
      mayWrite: (s) => s.permissionMode != 'plan',
      excluding: excluding,
    ))
      s.id,
  ];

  test('live writers in the checkout are counted, the asker is not', () {
    expect(
      writers([_session('a'), _session('b'), _session('me')], excluding: 'me'),
      ['a', 'b'],
    );
  });

  test('an idle session still holds the tree; an ended one does not', () {
    expect(
      writers([
        _session('idle', status: SessionStatus.idle),
        _session('done', status: SessionStatus.completed),
        _session('lost', status: SessionStatus.unknown),
      ]),
      ['idle'],
    );
  });

  test('a read-only session is not counted', () {
    expect(writers([_session('reader', mode: 'plan'), _session('w')]), ['w']);
  });

  test('archived sessions and other directories are not counted', () {
    expect(
      writers([
        _session('gone', archivedAt: DateTime.utc(2026, 10, 9)),
        _session(
          'elsewhere',
          workingDirectory: const EnvironmentPath(
            environmentId: 'win',
            path: r'C:\src\app-wt',
          ),
        ),
        _session(
          'other machine',
          workingDirectory: const EnvironmentPath(
            environmentId: 'wsl',
            path: r'C:\src\app',
          ),
        ),
      ]),
      isEmpty,
    );
  });

  test('a checkout attached to a session counts as working there', () {
    expect(
      writers(
        [_session('linked', workingDirectory: null)],
        attached: {
          'linked': [_checkout],
        },
      ),
      ['linked'],
    );
  });

  test('one tree spelled two ways is one checkout', () {
    expect(
      writers([
        _session(
          'upper',
          workingDirectory: const EnvironmentPath(
            environmentId: 'win',
            path: r'C:\SRC\APP',
          ),
        ),
      ]),
      ['upper'],
    );
  });

  test('the sentence names each, with agent and whether it works', () {
    expect(occupancySentence(const []), isNull);
    expect(
      occupancySentence([
        CheckoutOccupant(session: _session('x'), agentName: 'Claude'),
        CheckoutOccupant(
          session: _session('y', status: SessionStatus.idle),
          agentName: 'Codex',
        ),
      ]),
      '2 sessions are working in this checkout: Session x (Claude, working), '
      'Session y (Codex, idle).',
    );
    expect(
      CheckoutOccupant(session: _session('z')).toJson(),
      containsPair('activity', 'working'),
    );
  });
}
