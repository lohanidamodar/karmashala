import 'package:flutter_test/flutter_test.dart';
import 'package:karmashala/src/features/running/domain/port_label.dart';

void main() {
  PortLabel label(
    String? process,
    int port, {
    String? command,
    PortFacts facts = const PortFacts(),
  }) => labelPort(process: process, port: port, command: command, facts: facts);

  test('a node process is an http dev server, named by what it runs', () {
    expect(
      label('node.exe', 5173, command: 'npx vite').name,
      'Vite dev server',
    );
    expect(
      label('node', 3000, command: 'npm run dev -- next').name,
      'Next.js dev server',
    );
    final plain = label('node.exe', 8080);
    expect(plain.name, 'Node server');
    expect(plain.kind, PortKind.http);
  });

  test('a dart process is a VM service or DevTools when the facts say so', () {
    const facts = PortFacts(vmServicePorts: {51234}, devToolsPorts: {9100});
    expect(label('dart.exe', 51234, facts: facts).kind, PortKind.dartVmService);
    expect(label('dart.exe', 51234, facts: facts).name, 'Dart VM service');
    expect(label('dart.exe', 9100, facts: facts).kind, PortKind.devTools);
    expect(label('dart.exe', 9100, facts: facts).isHttp, isTrue);
    // Unknown to the facts: a Dart program, not a claim it is either.
    expect(label('dart.exe', 4000).name, 'Dart program');
  });

  test('databases and caches are named, and never offered as http', () {
    expect(label('postgres.exe', 5432).name, 'PostgreSQL');
    expect(label('postgres.exe', 5432).isHttp, isFalse);
    expect(label('redis-server', 6379).name, 'Redis');
    expect(label('redis-server', 6379).kind, PortKind.database);
    expect(label('mysqld', 3306).name, 'MySQL');
    expect(label('mongod', 27017).name, 'MongoDB');
  });

  test('device mirroring and python servers are named', () {
    expect(label('adb.exe', 5037).kind, PortKind.device);
    expect(label('scrcpy.exe', 27183).name, 'scrcpy');
    expect(label('python.exe', 8000).isHttp, isTrue);
    expect(
      label('python3', 8000, command: 'uvicorn main:app').name,
      'Uvicorn server',
    );
  });

  test('an unknown process keeps its own name and is not called http', () {
    final other = label('mystery.exe', 1234);
    expect(other.name, 'mystery');
    expect(other.kind, PortKind.other);
    expect(other.isHttp, isFalse);
    expect(label(null, 1234).name, 'Unknown process');
  });
}
