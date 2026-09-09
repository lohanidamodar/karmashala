/// Finding the environments, and the CLIs installed in each of them.
///
/// `EnvironmentDiscoveryService` enumerates this machine plus every WSL
/// distribution on it; `AgentDiscoveryService` probes each (environment, agent)
/// pair from the descriptor table and reports what it found, what it could not
/// reach, and how old each reading is.
library;

export 'src/agents/data/agent_discovery_service.dart';
export 'src/agents/domain/agent_discovery_report.dart';
export 'src/agents/domain/agent_installation.dart';
export 'src/agents/domain/agent_path_repair.dart';
export 'src/agents/domain/agent_version_reading.dart';
export 'src/environments/environment_discovery_service.dart';
export 'src/util/clock.dart';
export 'src/util/id_generator.dart';
export 'src/util/path_probe.dart';
