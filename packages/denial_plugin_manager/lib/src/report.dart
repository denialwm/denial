import 'activation.dart';
import 'progress.dart';
import 'rebuild.dart';
import 'store.dart';
import 'workspace.dart';

/// The version of `summary` in `denial-plugins status --json` and of
/// `denial-plugins list --json`. Another program, such as Settings, displays
/// them and works nothing out itself (PLUGIN_MANAGER.md section 23). A new
/// field or a new code keeps the number; a changed meaning raises it.
const statusContract = 1;

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : const {};

/// A sentence with the code that names it. A program that knows the code
/// words it itself, in the user's language; otherwise it shows [text].
Map<String, Object?> _line(
  String code,
  String text, [
  Map<String, Object?> facts = const {},
]) => {'code': code, 'text': text, ...facts};

/// `denial_top_bar` reads "Top Bar".
String pluginTitle(String name) => name
    .replaceFirst(RegExp(r'^denial_'), '')
    .split('_')
    .where((word) => word.isNotEmpty)
    .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
    .join(' ');

/// Every plugin this installation knows, for `denial-plugins list`: built-in
/// ones, ones added before, and the catalog's.
List<Map<String, Object?>> pluginList(
  ManagerStore store,
  Map<String, Object?> catalog,
) {
  final selected = (store.selection['roots']! as Map).keys.toSet();
  final installed = store.read('installed.json')['plugins'] as Map? ?? const {};
  final defaults = {
    for (final plugin in catalog['builtins'] as List? ?? const [])
      if (plugin is Map && plugin['default'] == true) plugin['name'],
  };
  final plugins = <String, Map<String, Object?>>{};
  void add(Object? plugin, {required bool installed}) {
    if (plugin is! Map || plugin['name'] is! String) return;
    final name = plugin['name'] as String;
    if (plugins.containsKey(name)) return;
    final source = plugin['source'] as Map?;
    plugins[name] = {
      'name': name,
      'title': pluginTitle(name),
      'description': plugin['description'],
      // builtin, local or git.
      'kind': source?['kind'],
      'from': switch (source?['kind']) {
        'builtin' => 'built in',
        _ => source?['location'],
      },
      'source': source,
      'installed': installed,
      'selected': selected.contains(name),
      'default': defaults.contains(name),
    };
  }

  for (final plugin in installed.values) {
    add(plugin, installed: true);
  }
  for (final plugin in catalog['builtins'] as List? ?? const []) {
    add(plugin, installed: true);
  }
  for (final plugin
      in (catalog['catalog'] as Map?)?['entries'] as List? ?? const []) {
    add(plugin, installed: false);
  }
  return plugins.values.toList()
    ..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));
}

/// What `denial-plugins list --json` prints.
Map<String, Object?> listReport(
  ManagerStore store,
  Map<String, Object?> catalog,
) => {
  'contract': statusContract,
  'plugins': pluginList(store, catalog),
  // Whether the selection is exactly the plugins Denial comes with.
  'default_selection': _defaultSelection(store, catalog),
  // The community list: whether one is set, and when it was last read.
  'community': {
    'configured': catalog['configured'] == true,
    'updated': (catalog['catalog'] as Map?)?['updated'],
  },
  // The community list could not be loaded; built-in plugins still work.
  'errors': [
    for (final error
        in (catalog['catalog'] as Map?)?['errors'] as List? ?? const [])
      '$error',
  ],
};

bool _defaultSelection(ManagerStore store, Map<String, Object?> catalog) {
  final roots = _map(store.selection['roots']);
  final defaults = {
    for (final plugin in catalog['builtins'] as List? ?? const [])
      if (plugin is Map && plugin['default'] == true) plugin['name'],
  };
  return roots.length == defaults.length &&
      roots.entries.every(
        (root) =>
            defaults.contains(root.key) &&
            _map(_map(root.value)['source'])['kind'] == 'builtin',
      );
}

/// Requests only: what a request runs inside itself is its own business.
List<Map<String, Object?>> _requests(Object? jobs) => [
  for (final job in jobs as List? ?? const [])
    if (job is Map && _map(job['arguments'])['request'] == null)
      job.cast<String, Object?>(),
];

/// What a request was asked to do: `apply` also when a terminal ran it.
String _operation(Map<String, Object?> job) =>
    _map(job['arguments'])['command'] as String? ??
    job['operation'] as String? ??
    '';

/// When a request ended, or last said something.
String _ended(Map<String, Object?> job) =>
    '${job['updated'] ?? job['created'] ?? ''}';

/// What `denial-plugins history --json` prints: the requests this manager
/// remembers, the newest first. Looking into a folder or a link is no
/// request worth remembering, and a record from before requests said what
/// they were asked says too little to show.
Map<String, Object?> historyReport(List<Map<String, Object?>> jobs) {
  final requests =
      _requests(jobs)
          .where(
            (job) =>
                job['operation'] != 'inspect' &&
                (job['operation'] != 'plan' ||
                    _map(job['arguments'])['command'] != null),
          )
          .toList()
        ..sort((a, b) => _ended(b).compareTo(_ended(a)));
  return {
    'contract': statusContract,
    'entries': [
      for (final job in requests)
        () {
          final state = switch (job['phase']) {
            'queued' => 'waiting',
            'running' => 'working',
            'succeeded' => 'done',
            'interrupted' => 'stopped',
            _ => 'failed',
          };
          final over = state == 'failed' || state == 'stopped';
          final detail = '${job['error'] ?? ''}'.trim();
          final code = state == 'stopped' ? 'stopped' : failureCode(detail);
          return {
            'job': job['id'],
            'operation': _operation(job),
            'state': state,
            'when': _ended(job),
            if (over) ...{
              'code': code,
              'text': _failureText(code),
              'detail': detail,
            },
          };
        }(),
    ],
  };
}

String describeHistory(Map<String, Object?> history) {
  final entries = (history['entries']! as List).cast<Map<String, Object?>>();
  if (entries.isEmpty) return 'Nothing was asked yet.';
  return [
    for (final entry in entries)
      '${'${entry['when']}'.padRight(28)}'
          '${'${entry['operation']}'.padRight(16)}'
          '${entry['state']}'
          '${'${entry['detail'] ?? ''}'.isEmpty ? '' : ': ${entry['detail']}'}',
  ].join('\n');
}

String describePlugins(List<Map<String, Object?>> plugins) {
  if (plugins.isEmpty) return 'No plugins are known yet.';
  final width = plugins
      .map((plugin) => (plugin['name']! as String).length)
      .reduce((a, b) => a > b ? a : b);
  return [
    for (final plugin in plugins)
      '${plugin['selected'] == true ? 'on ' : '   '} '
          '${(plugin['name']! as String).padRight(width)}  '
          '${plugin['from'] ?? ''}',
    '',
    'on = selected. denial-plugins add NAME, denial-plugins remove NAME, then denial-plugins apply.',
  ].join('\n');
}

/// Why an operation failed, from the message it ended with. The messages are
/// this package's own and deniald's.
String failureCode(String error) {
  if (error.contains('plugin bundle source does not match installed Denial')) {
    return 'other_denial';
  }
  if (error.contains('compatibility declarations')) return 'declaration';
  // What the selection check says before anything is built.
  if (error.contains('Disable') && error.contains('before applying.')) {
    return 'conflict';
  }
  if (error.contains('Enable a compatible plugin before applying.')) {
    return 'missing';
  }
  if (error.contains('#ShellPanel; found') &&
      !error.contains('found 0 providers')) {
    return 'two_panels';
  }
  if (RegExp(r'found (?:[2-9]|[1-9][0-9]+) providers').hasMatch(error)) {
    return 'conflict';
  }
  if (error.contains('found 0 providers') ||
      error.contains('has no provider') ||
      error.contains('no provider is enabled')) {
    return 'missing';
  }
  if (error.contains('Log out and back')) return 'log_in_again';
  if (error.contains('did not start')) return 'did_not_start';
  if (error.contains('SocketException') ||
      error.contains('Could not resolve host') ||
      error.contains('Connection timed out')) {
    return 'download';
  }
  return 'failed';
}

String _failureText(String code) => switch (code) {
  'other_denial' =>
    'Your plugins were built for another Denial. Apply builds them again.',
  'declaration' => 'A plugin describes itself wrongly. The details name it.',
  'two_panels' =>
    'More than one desktop panel is selected. Keep one, then apply again.',
  'conflict' =>
    'Several plugins provide the same feature. Keep one, then apply again.',
  'missing' => 'A feature the desktop needs is missing. Turn on a plugin that provides it, then apply again.',
  'log_in_again' => 'Log out and back into Denial once, then apply again.',
  'did_not_start' => 'Your plugins were built but did not start. Denial kept the desktop it was running.',
  'download' => 'A download failed. Check the connection and apply again.',
  'stopped' => 'The last change was stopped before it finished.',
  _ => 'The last change failed. The details say why.',
};

/// What `denial-plugins status` says: what runs, why, and what to do next.
/// [state] is the status the command gathered.
Map<String, Object?> summarize(ManagerStore store, Map<String, Object?> state) {
  final native = _map(state['native']);
  final selection = _map(state['selection']);
  final active = _map(state['active']);
  final selected = _map(selection['roots']).keys.toList()..sort();
  final why = <Map<String, Object?>>[];
  Map<String, Object?>? next;
  const apply = {'code': 'apply', 'text': 'denial-plugins apply'};

  final reachable = native['available'] != false;
  final capable =
      reachable &&
      (native['capabilities'] as List? ?? const []).contains(bundleCapability);
  final custom =
      reachable &&
      native['plugin_bundle'] is String &&
      native['active_mode'] == 'custom_optimized';

  final Map<String, Object?> desktop;
  if (!reachable) {
    desktop = _line('unreachable', 'Denial does not answer in this session.');
    why.add(_line('session_error', '${native['error']}'.trim()));
    next = _line(
      'open_in_session',
      'Run this from a terminal inside your Denial session.',
    );
  } else if (custom) {
    final id = active['id'] as String?;
    if (id == null) {
      desktop = _line(
        'other_plugins',
        'Plugins built outside this plugin manager are running: ${native['plugin_bundle']}',
        {'bundle': native['plugin_bundle']},
      );
    } else {
      final plan = store.read('candidates/$id/plan.json');
      final running = _map(plan['roots']).keys.toList()..sort();
      desktop = _line(
        'plugins',
        'Your plugins are running: ${running.join(', ')}',
        {'plugins': running},
      );
      if (!sameComposition(selection, plan)) {
        why.add(
          _line(
            'selection_changed',
            'Your selection changed since then: ${selected.join(', ')}',
          ),
        );
        next = apply;
      }
    }
    if (native['plugin_engine_differs'] == true) {
      why.add(
        _line(
          'engine_differs',
          'They were built for another engine than this session runs, and loaded anyway.',
        ),
      );
    }
    if (native['plugin_healthy'] != true) {
      why.add(_line('starting', 'They are still starting.'));
    }
  } else {
    desktop = _line('standard', 'The standard desktop is running.');
  }

  final rebuild = _map(native['plugin_rebuild']);
  if (reachable && rebuild['bundle'] is String) {
    final version = rebuild['version'];
    why.add(switch (rebuild['reason']) {
      'engine' => _line(
        'rebuild_engine',
        'Your plugins did not start on this session\'s engine. They have to be built again.',
      ),
      _ => _line(
        'rebuild_update',
        'Denial changed since your plugins were built. They have to be built again.',
        {
          'version': ?(version is String && isReleaseVersion(version)
              ? version
              : null),
        },
      ),
    });
    next = apply;
  }
  final error = native['error'];
  if (reachable && !custom && error is String && error.trim().isNotEmpty) {
    why.add(
      _line('denial_said', 'Denial said: ${error.trim()}', {
        'message': error.trim(),
      }),
    );
  }

  // What stops the saved selection from being built at all.
  final issues = [
    for (final issue in _map(state['preflight'])['issues'] as List? ?? const [])
      if (issue is Map)
        {
          'code': issue['code'],
          'text': issue['message'],
          'plugins': issue['plugins'] ?? const <String>[],
          'feature': ?_map(issue['requirement'])['label'],
        },
  ];

  final requests = _requests(state['jobs']);
  const operation = _operation;
  const ended = _ended;
  final working = requests
      .where((job) => {'queued', 'running'}.contains(job['phase']))
      .firstOrNull;
  // The request that ended last: one refused because another was running
  // ended before that other one did.
  final finished = requests
      .where(
        (job) =>
            {'succeeded', 'failed', 'interrupted'}.contains(job['phase']) &&
            !{'inspect', 'refresh-catalog'}.contains(job['operation']),
      )
      .fold<Map<String, Object?>?>(
        null,
        (latest, job) =>
            latest == null || ended(job).compareTo(ended(latest)) > 0
            ? job
            : latest,
      );

  Map<String, Object?>? work;
  if (working != null) {
    final progress = switch (working['progress']) {
      final Map progress => progress.cast<String, Object?>(),
      _ => switch (working['message']) {
        final String message => jobProgress(operation(working), message),
        _ => null,
      },
    };
    work = {
      'job': working['id'],
      'operation': operation(working),
      // One of the labels of progress.dart; a protocol value, never reworded.
      'label':
          progress?['label'] ??
          (working['phase'] == 'queued'
              ? 'Waiting to start'
              : working['operation'] == 'refresh-catalog'
              ? 'Reading the community list'
              : 'Working on your changes'),
      'step': switch (progress?['completed']) {
        final int completed => completed + 1,
        _ => null,
      },
      'steps': progress?['total'],
      // When this step began; a clock counts from it.
      'started':
          progress?['started'] ?? working['updated'] ?? working['created'],
    };
  }

  Map<String, Object?>? failure;
  if (working == null && finished != null && finished['phase'] != 'succeeded') {
    final detail = '${finished['error'] ?? ''}'.trim();
    final code = finished['phase'] == 'interrupted'
        ? 'stopped'
        : failureCode(detail);
    failure = {
      'job': finished['id'],
      'operation': operation(finished),
      'code': code,
      'text': _failureText(code),
      'detail': detail,
    };
  }

  // What the last build of this very selection took in besides the
  // selected plugins, and through which of them.
  final plan = _map(state['plan']);
  final discovery = _map(plan['discovery']);
  final roots = _map(selection['roots']);
  final included = [
    if (plan['selectionRevision'] != null &&
        plan['selectionRevision'] == selection['revision'])
      for (final name
          in (discovery['plugins'] as List? ?? const []).whereType<String>())
        if (!roots.containsKey(name))
          {
            'name': name,
            'title': pluginTitle(name),
            // From a selected plugin down to the one that needs it.
            'through': switch (_map(discovery['dependencyChains'])[name]) {
              final List chain when chain.length > 2 => chain.sublist(
                1,
                chain.length - 1,
              ),
              _ => const <String>[],
            },
          },
  ];

  // Whether this installation can build plugins at all.
  final dart = _map(state['dart']);
  final problem = state['problem'] as String?;
  final Map<String, Object?> setup;
  if (problem != null) {
    setup =
        dart['available'] == false &&
            dart['version'] is String &&
            dart['constraint'] is String
        ? _line('incompatible_dart', problem, {
            'installed': dart['version'],
            'required': dart['constraint'],
          })
        : dart['available'] == false && dart['expectedVersion'] is String
        ? _line('missing_dart', problem, {'expected': dart['expectedVersion']})
        : _line('tools', problem);
  } else if (state['ready'] == true) {
    setup = _line('ready', 'Plugin support is ready.');
  } else if (working != null &&
      {'initialize', 'prepare'}.contains(working['operation'])) {
    setup = _line('preparing', 'Plugin support is being prepared.');
  } else {
    setup = _line(
      'needed',
      'Plugin support is prepared the first time you apply.',
    );
  }

  if (reachable && !capable) {
    why.add(
      _line(
        'session_old',
        'This session\'s Denial is older than this plugin manager and cannot load what it builds.',
      ),
    );
    next = _line('log_in_again', 'Log out and back into Denial once.');
  }
  if (issues.isNotEmpty && next?['code'] != 'log_in_again' && reachable) {
    next = _line(
      'fix_selection',
      'Change your selection with denial-plugins add or remove, then denial-plugins apply.',
    );
  }
  if (problem != null) next = null;
  if (work != null) {
    next = _line('wait', 'Wait for it, then denial-plugins status.');
  } else if (capable && problem == null && issues.isEmpty) {
    if (failure != null &&
        {'plan', 'apply', 'update', 'rebuild'}.contains(failure['operation'])) {
      next ??= apply;
    }
    if (!custom && selected.isNotEmpty && rebuild['bundle'] is! String) {
      next ??= apply;
    }
  }

  final idle = work == null;
  return {
    'contract': statusContract,
    'desktop': desktop,
    'selected': selected,
    'why': why,
    'issues': issues,
    'included': included,
    'setup': setup,
    'work': work,
    'failure': failure,
    'next': next,
    // What a program may offer now. Apply is always allowed where it can
    // work: in a development checkout it is also how edits are tried.
    'can': {
      'change': idle && problem == null,
      'apply': idle && capable && problem == null && issues.isEmpty,
      'undo': idle && reachable && native['plugin_previous'] is String,
      'off': idle && custom,
      'switch_now':
          work != null &&
          work['operation'] == 'rebuild' &&
          work['label'] == 'Switching when you pause',
    },
  };
}

String describeStatus(Map<String, Object?> summary) {
  final selected = (summary['selected']! as List).cast<String>();
  final setup = _map(summary['setup']);
  final work = summary['work'] as Map?;
  final failure = summary['failure'] as Map?;
  return [
    _map(summary['desktop'])['text'],
    'Selected: ${selected.isEmpty ? 'nothing' : selected.join(', ')}',
    for (final line in summary['why']! as List) '  ${(line as Map)['text']}',
    for (final issue in summary['issues']! as List)
      '  ${(issue as Map)['text']}',
    if ({'tools', 'missing_dart', 'incompatible_dart'}.contains(setup['code']))
      '  ${setup['text']}',
    if (work != null)
      '  Working: ${work['label']}'
          '${work['step'] == null ? '' : ' (step ${work['step']} of ${work['steps']})'}',
    if (failure != null)
      '  The last change failed: '
          '${'${failure['detail']}'.isEmpty ? failure['text'] : failure['detail']}',
    if (summary['next'] case final Map next) 'Next: ${next['text']}',
  ].join('\n');
}
