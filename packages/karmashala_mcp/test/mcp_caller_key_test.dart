import 'package:karmashala_mcp/protocol.dart';
import 'package:test/test.dart';

void main() {
  test('a token names its session, for this key only, every time', () {
    final key = McpCallerKey.generate();
    final token = key.tokenFor('a1b2.c3');
    expect(key.tokenFor('a1b2.c3'), token);
    expect(McpCallerKey(key.secret).sessionFor(token), 'a1b2.c3');
    expect(McpCallerKey.generate().sessionFor(token), isNull);
  });

  test('a token altered anywhere names nobody', () {
    final key = McpCallerKey.generate();
    final token = key.tokenFor('s1');
    expect(key.sessionFor(token.replaceFirst('s1', 's2')), isNull);
    expect(key.sessionFor('${token}x'), isNull);
    expect(key.sessionFor('s1'), isNull);
    expect(key.sessionFor('s1.'), isNull);
    expect(key.sessionFor(''), isNull);
  });
}
