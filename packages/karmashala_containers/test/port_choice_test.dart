import 'package:karmashala_containers/karmashala_containers.dart';
import 'package:test/test.dart';

void main() {
  test('reads ss, netstat and docker ps output', () {
    const output = '''
LISTEN 0      128        127.0.0.1:41000      0.0.0.0:*
LISTEN 0      4096           [::]:22             [::]:*
tcp        0      0 0.0.0.0:41001           0.0.0.0:*               LISTEN
127.0.0.1:41002->22/tcp
0.0.0.0:8080->80/tcp, :::8080->80/tcp
not a line we know
''';
    expect(
      parseListeningPorts(output),
      containsAll(<int>{41000, 22, 41001, 41002, 8080}),
    );
    expect(parseListeningPorts(output), isNot(contains(80)));
    expect(parseListeningPorts(output), isNot(contains(0)));
  });

  test('chooses the first free port in the range', () {
    expect(chooseContainerPort({}), 41000);
    expect(chooseContainerPort({41000, 41001, 41003}), 41002);
  });

  test('a port saved for another machine counts as taken', () {
    final listening = parseListeningPorts('LISTEN 0 1 127.0.0.1:41000 *:*');
    expect(chooseContainerPort({...listening, 41001}), 41002);
  });

  test('a full range has no port', () {
    expect(chooseContainerPort({1, 2, 3}, range: (first: 1, last: 3)), isNull);
  });
}
