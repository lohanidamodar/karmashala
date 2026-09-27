/// The terminal tools the server runs (slice 5b), moved from the app with
/// their names and schemas unchanged. The server keeps no tabs: every
/// terminal it runs is listed as a tab of one pane, whose id is the pane id.
const List<Map<String, Object?>> terminalControlToolSchemas = [
  {
    'name': 'terminal_list',
    'description':
        'Every terminal the Karmashala server runs — shells, agent sessions, '
        'runs — each listed as a tab holding one pane (the tab id is the pane '
        'id), the one in front of the person marked active. Every terminal '
        'keeps running in the server whether or not a window shows it, so '
        '"detached" is always empty. Also lists the shell profiles this '
        'machine offers, which is where terminal_open gets its profileId. '
        'Start here — every other terminal tool takes an id from this one.',
    // An empty `properties` as well as `additionalProperties: false`: the spec
    // accepts either, and this repo asserts every schema carries a properties map.
    'inputSchema': {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'activeTabId': {
          'type': ['string', 'null'],
        },
        'tabs': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'active': {'type': 'boolean'},
              'focusedPaneId': {'type': 'string'},
              'panes': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'paneId': {'type': 'string'},
                    'title': {'type': 'string'},
                    'profileId': {
                      'type': ['string', 'null'],
                    },
                    'workingDirectory': {
                      'type': ['string', 'null'],
                    },
                    'live': {'type': 'boolean'},
                  },
                  'required': ['paneId', 'live'],
                },
              },
            },
            'required': ['id', 'panes'],
          },
        },
        'detached': {
          'type': 'array',
          'items': {'type': 'object'},
        },
        'profiles': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['tabs', 'detached', 'profiles'],
    },
  },
  {
    'name': 'terminal_open',
    'description':
        'Open a new terminal and return its tab and pane ids. The Karmashala '
        'server runs it, and the Karmashala window a person is using shows it '
        'as a tab, so the user can see and take over whatever runs in it; '
        'with no window open it still runs, and the answer says so. Pass '
        'profileId to choose the shell — an unknown one is refused rather than '
        'quietly substituted, because a WSL command run in PowerShell is not a '
        'smaller version of the same thing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'profileId': {
          'type': 'string',
          'description':
              'A profile id from terminal_list. Defaults to the first one, '
              'which is PowerShell on Windows.',
        },
        'workingDirectory': {
          'type': 'string',
          'description':
              'Where the shell starts. Must be a path the chosen shell can '
              'reach: a WSL profile needs a Linux path, a Windows one needs a '
              'Windows path.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'string'},
        'paneId': {'type': 'string'},
        'profileId': {'type': 'string'},
        'workingDirectory': {
          'type': ['string', 'null'],
        },
      },
      'required': ['tabId', 'paneId', 'profileId'],
    },
  },
  {
    'name': 'terminal_run',
    'description':
        'Run a command in a terminal pane and WAIT for it to finish, then '
        'return that command\'s own output and its exit code — one round trip, '
        'the way your own shell tool works. Prefer this over spawning a shell '
        'of your own: the pane is Karmashala\'s, so the user can watch it, take '
        'it over, and keep it after you are gone. Read `finished` and '
        '`exitCodeKnown` before you believe anything: a command still running '
        'at the timeout comes back finished=false with the partial output it '
        'has printed so far (pass a small timeoutSeconds for a dev server you '
        'mean to leave running), and a pane whose shell has no OSC 133 '
        'integration — PowerShell is the only one that has it today — comes '
        'back at once with exitCodeKnown=false, because it cannot know. No '
        'exit code is ever invented. Refuses a pane that is running an agent '
        'CLI: that is somebody\'s live session, not a shell. Whatever the '
        'command does is the command\'s business — this tool cannot tell a '
        'build from an rm -rf.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'Which pane, from terminal_list.',
        },
        'command': {'type': 'string', 'description': 'The command to run.'},
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to wait for the command before answering "still '
              'running" with what it has printed (default 60, max 600). '
              'Nothing is killed on timeout — the command keeps running in the '
              'pane.',
        },
      },
      'required': ['paneId', 'command'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'command': {'type': 'string'},
        'finished': {'type': 'boolean'},
        'exitCode': {
          'type': ['number', 'null'],
        },
        'exitCodeKnown': {'type': 'boolean'},
        'durationMs': {
          'type': ['number', 'null'],
        },
        'output': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'note': {'type': 'string'},
      },
      'required': [
        'paneId',
        'command',
        'finished',
        'exitCodeKnown',
        'output',
        'note',
      ],
    },
  },
  {
    'name': 'terminal_output',
    'description':
        'Read the recent output of a terminal pane — the screen as it stands, '
        'newest last. This is what a pane shows, not a log: lines that '
        'scrolled out of the buffer are gone.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {
          'type': 'string',
          'description': 'Which pane, from terminal_list.',
        },
        'lines': {
          'type': 'number',
          'description': 'How many trailing lines (default 40, max 500).',
        },
      },
      'required': ['paneId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'paneId': {'type': 'string'},
        'title': {'type': 'string'},
        'live': {'type': 'boolean'},
        'lines': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['paneId', 'lines'],
    },
  },
  {
    'name': 'terminal_close',
    'description':
        'Close a terminal tab. A pane that is doing something — an agent '
        'session, a running command, a shell with real history — is DETACHED '
        'rather than ended: the window closes its tab and it keeps running in '
        'the Karmashala server, still listed by terminal_list, which is how a '
        'long build survives its tab being tidied away. An idle shell that has '
        'printed nothing is ended, because there is nothing to come back for. '
        'The result says which happened to each pane. Pass kill=true to skip '
        'that entirely and end them all — DESTRUCTIVE, and nothing brings back '
        'what they were part-way through.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {
          'type': 'string',
          'description': 'Which tab, from terminal_list.',
        },
        'kill': {
          'type': 'boolean',
          'description':
              'End the panes\' processes instead of detaching them. Default '
              'false.',
        },
      },
      'required': ['tabId'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'tabId': {'type': 'string'},
        'closed': {'type': 'boolean'},
        'panes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'paneId': {'type': 'string'},
              'outcome': {'type': 'string'},
            },
            'required': ['paneId', 'outcome'],
          },
        },
      },
      'required': ['tabId', 'closed', 'panes'],
    },
  },
];
