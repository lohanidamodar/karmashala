/// The schemas of the session tools the server answers for a session it
/// holds, moved from the app with their words unchanged.
library;

const List<Map<String, Object?>> sessionControlToolSchemas = [
  {
    'name': 'session_send',
    'description':
        'Send a message to a session, exactly as typing it into that '
        'session\'s message box would. Omit sessionId to send to the session '
        'you are running in. A session whose agent has stopped is relaunched '
        'and resumed first, so this works whether or not it is live. A message '
        'to another session arrives with a line naming yours, so the recipient '
        'reads it as a request from a peer rather than as an instruction from '
        'the user; the line is built from the session the transport '
        'authenticated, so you can neither borrow another name nor drop your '
        'own. Refused while the target has an approval prompt open: the '
        'keystrokes would land in that prompt instead — answer it with '
        'session_answer, or wait. Pass wait: true to block until the session '
        'settles afterwards — the common send-then-wait shape. The block is '
        'checked BEFORE the send, so a target already waiting on a person is '
        'refused with nothing sent.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session. This selects a '
              'target; it does not change who you are.',
        },
        'text': {'type': 'string', 'description': 'The message to send.'},
        'wait': {
          'type': 'boolean',
          'description':
              'Block until the session settles after delivering, adding every '
              'session_wait field to the result. Refused before sending if the '
              'target is already blocked on a person.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to wait, when wait is true. Default 30, capped at 45.',
        },
      },
      'required': ['text'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'delivered': {'type': 'boolean'},
        'attribution': {
          'type': ['string', 'null'],
          'description':
              'The line prepended to the message naming you as its sender, or '
              'null when nothing was prepended — a message to yourself, or a '
              'caller running in no session of ours.',
        },
        'live': {
          'type': 'boolean',
          'description': 'Whether the session has a live pane.',
        },
      },
      'required': ['sessionId', 'delivered'],
    },
  },
  {
    'name': 'session_answer',
    'description':
        'Answer a session\'s on-screen approval prompt. When the prompt is a '
        'menu (folder trust, a tool permission), this chooses the option that '
        'agent is known to mean yes or no by — never whatever happens to be '
        'highlighted — and `answered` names it; otherwise it presses the key '
        'the agent itself names for approve or deny. Fails, rather than '
        'guessing, when no option or key for the decision you asked for can '
        'be named. Use session_transcript first to see what is being asked.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'decision': {
          'type': 'string',
          'enum': ['approve', 'deny'],
          'description': 'What to answer.',
        },
      },
      'required': ['decision'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'answered': {
          'type': 'string',
          'description':
              "The menu option chosen, in the agent's own words — or, for a "
              "prompt that is not a menu, the label of the key pressed.",
        },
        'effect': {'type': 'string'},
      },
      'required': ['sessionId', 'answered'],
    },
  },
  {
    'name': 'session_wait',
    'description':
        'Block until a session settles, so you can hand work to another agent '
        'and know when it is done instead of re-reading its transcript on a '
        'loop. Five answers. "idle" and "done" both mean ready for input, and '
        'they are two states on purpose: "done" is idle-and-seen-changed, so a '
        'session that finished something does not read like one that never '
        'started. "blocked" means it has stopped for a person — an approval or '
        'a question — and names what it is waiting on. "ended" means the pane '
        'is gone, with the exit code when one was learned and never a zero '
        'when none was. "timeout" is YOUR bound and not a verdict: the session '
        'is still running, and inputSent says whether anything was delivered, '
        'so call again rather than sending the same work twice. On "idle" and '
        '"done", finalAnswer is its last message from its record. Nothing '
        'here polls — the wait completes on the events the app already sees.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session — which would '
              'wait for YOU, and never settle. Name the session you delegated '
              'to.',
        },
        'timeoutSeconds': {
          'type': 'number',
          'description':
              'How long to block. Default 30, capped at 45 — the transports '
              'between you and this app give up at 60.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'state': {
          'type': 'string',
          'enum': ['idle', 'done', 'blocked', 'ended', 'timeout'],
        },
        'agentStatus': {
          'type': 'string',
          'description':
              'The status word behind the state, so a turn that ended in an '
              'error is not flattened into "ready for input".',
        },
        'evidenceSource': {
          'type': 'string',
          'description':
              'What told us: hook, stateFile, terminalGrid, or none.',
        },
        'since': {
          'type': ['string', 'null'],
          'description':
              'When the evidence was produced — never when we looked. Null '
              'when no source could tell us anything.',
        },
        'evidenceAgeSeconds': {
          'type': ['number', 'null'],
          'description': 'How old that evidence was when this answered.',
        },
        'changed': {
          'type': 'boolean',
          'description':
              'Whether the session moved while this call watched. The one '
              'thing that separates done from idle.',
        },
        'transcriptChanged': {
          'type': ['boolean', 'null'],
          'description':
              'Whether the conversation moved, or null when no source could '
              'see it — which is never the same as "it said nothing".',
        },
        'transcriptChangedSource': {'type': 'string'},
        'blockedOn': {
          'type': ['object', 'null'],
          'description':
              'What it is waiting on, in the source\'s own words. Null unless '
              'the state is blocked.',
          'properties': {
            'kind': {'type': 'string'},
            'text': {
              'type': ['string', 'null'],
            },
          },
        },
        'exitCode': {
          'type': ['number', 'null'],
        },
        'exitCodeKnown': {
          'type': 'boolean',
          'description':
              'Read this before believing exitCode. A missing code is UNKNOWN '
              '— it is never a zero.',
        },
        'inputSent': {
          'type': ['boolean', 'null'],
          'description':
              'Whether this call delivered anything before waiting. Null means '
              'it sent nothing, which is a third answer and not a false.',
        },
        'note': {'type': 'string'},
      },
      'required': ['sessionId', 'state', 'changed', 'note'],
    },
  },
  {
    'name': 'session_transcript',
    'description':
        'Read what a session has said. Returns its recorded turns and, when it '
        'has a live pane, the current screen. Either source may be absent: a '
        'PTY-hosted session keeps no event log, and a stopped session has no '
        'screen. An absent source says "not recorded" — it is never reported '
        'as the session having said nothing.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'limit': {
          'type': 'number',
          'description': 'Most recent turns and screen lines (default 20).',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'status': {'type': 'string'},
        'live': {'type': 'boolean'},
        'turns': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'seq': {'type': 'number'},
              'role': {
                'type': 'string',
                'enum': ['user', 'agent'],
              },
              'at': {'type': 'string'},
              'text': {'type': 'string'},
            },
            'required': ['seq', 'role', 'text'],
          },
        },
        'omittedTurns': {'type': 'number'},
        'turnsSource': {'type': 'string'},
        'screen': {
          'type': ['array', 'null'],
          'items': {'type': 'string'},
        },
        'screenSource': {'type': 'string'},
      },
      'required': ['sessionId', 'turns', 'turnsSource', 'screenSource'],
    },
  },
  {
    'name': 'session_rename',
    'description':
        'Rename a session. The title is what every list and tab shows, so this '
        'is how a session stops being called "Agent session".',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description': 'Which session. Defaults to the calling session.',
        },
        'title': {'type': 'string', 'description': 'The new title.'},
      },
      'required': ['title'],
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
      },
      'required': ['sessionId', 'title'],
    },
  },
  {
    'name': 'session_end',
    'description':
        'Stop the agent process behind a session. DESTRUCTIVE: the turn in '
        'flight is lost and nothing brings it back. The session row and its '
        'transcript survive, and open_session will resume it. Fails if the '
        'session has no live pane, rather than reporting success for something '
        'that was already stopped.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {
          'type': 'string',
          'description':
              'Which session. Defaults to the calling session — which ends '
              'YOUR OWN agent, mid-turn. Name a session id unless that is '
              'genuinely what you mean.',
        },
      },
    },
    'outputSchema': {
      'type': 'object',
      'properties': {
        'sessionId': {'type': 'string'},
        'title': {'type': 'string'},
        'ended': {'type': 'boolean'},
        'paneId': {'type': 'string'},
      },
      'required': ['sessionId', 'ended'],
    },
  },
];
