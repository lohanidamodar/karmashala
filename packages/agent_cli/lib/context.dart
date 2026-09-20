/// **What a session started in one directory would be given** — its MCP
/// servers and its skills, read off configuration files, each row naming where
/// it came from and whether it would actually be bound.
///
/// Never what a *running* session has: an agent binds its servers when it
/// starts and owns those processes. Everything here is a reading of files, and
/// it carries the age of that reading like every other one.
library;

export 'src/agents/domain/agent_context.dart';
