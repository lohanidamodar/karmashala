/// What a listening port is, named from its process and the facts the app
/// already holds — never by probing the port.
library;

enum PortKind {
  http,
  dartVmService,
  devTools,
  database,
  device,
  karmashala,
  other,
}

/// Ports the app already knows by what they are: the VM services and DevTools
/// of the Flutter apps it has found.
class PortFacts {
  const PortFacts({
    this.vmServicePorts = const {},
    this.devToolsPorts = const {},
  });

  final Set<int> vmServicePorts;
  final Set<int> devToolsPorts;
}

class PortLabel {
  const PortLabel(this.name, this.kind);

  final String name;
  final PortKind kind;

  /// Whether a browser can open it: offered only for what serves http.
  bool get isHttp => kind == PortKind.http || kind == PortKind.devTools;
}

/// Names [port] held by [process], from [command] (the owning pane's last
/// command line) and [facts]. An unknown process keeps its own name.
PortLabel labelPort({
  required String? process,
  required int port,
  String? command,
  PortFacts facts = const PortFacts(),
}) {
  if (process == null || process.isEmpty) {
    return const PortLabel('Unknown process', PortKind.other);
  }
  final name = _stem(process);
  final line = (command ?? '').toLowerCase();
  bool runs(String word) => RegExp('\\b$word\\b').hasMatch(line);
  switch (name) {
    case 'node' || 'bun' || 'deno':
      if (runs('vite')) {
        return const PortLabel('Vite dev server', PortKind.http);
      }
      if (runs('next')) {
        return const PortLabel('Next.js dev server', PortKind.http);
      }
      if (runs('astro')) {
        return const PortLabel('Astro dev server', PortKind.http);
      }
      if (runs('svelte-kit') || runs('sveltekit')) {
        return const PortLabel('SvelteKit dev server', PortKind.http);
      }
      return PortLabel(switch (name) {
        'bun' => 'Bun server',
        'deno' => 'Deno server',
        _ => 'Node server',
      }, PortKind.http);
    case 'dart' || 'dartvm' || 'dartaotruntime' || 'flutter_tester':
      if (facts.vmServicePorts.contains(port)) {
        return const PortLabel('Dart VM service', PortKind.dartVmService);
      }
      if (facts.devToolsPorts.contains(port)) {
        return const PortLabel('DevTools', PortKind.devTools);
      }
      return const PortLabel('Dart program', PortKind.other);
    case 'python' || 'python3' || 'pythonw' || 'py':
      if (runs('uvicorn')) {
        return const PortLabel('Uvicorn server', PortKind.http);
      }
      if (runs('flask')) return const PortLabel('Flask server', PortKind.http);
      if (runs('manage.py') || runs('django')) {
        return const PortLabel('Django server', PortKind.http);
      }
      return const PortLabel('Python server', PortKind.http);
    case 'ruby' || 'rails' || 'puma':
      return const PortLabel('Ruby server', PortKind.http);
    case 'php':
      return const PortLabel('PHP server', PortKind.http);
    case 'nginx' || 'caddy' || 'httpd':
      return PortLabel(name, PortKind.http);
    case 'postgres' || 'postgresql':
      return const PortLabel('PostgreSQL', PortKind.database);
    case 'redis-server' || 'redis':
      return const PortLabel('Redis', PortKind.database);
    case 'mysqld' || 'mariadbd':
      return const PortLabel('MySQL', PortKind.database);
    case 'mongod':
      return const PortLabel('MongoDB', PortKind.database);
    case 'adb':
      return const PortLabel('adb server', PortKind.device);
    case 'scrcpy':
      return const PortLabel('scrcpy', PortKind.device);
    case 'karmashala_host' || 'karmashala':
      return const PortLabel('Karmashala', PortKind.karmashala);
  }
  return PortLabel(name, PortKind.other);
}

/// `node.exe` → `node`; a path's last part, lowercased.
String _stem(String process) {
  final last = process.split(RegExp(r'[\\/]')).last.toLowerCase();
  return last.endsWith('.exe') ? last.substring(0, last.length - 4) : last;
}
