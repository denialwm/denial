import '../../platform/denial_bridge.dart';
import '../models/desktop_app.dart';
import 'desktop_exec_parser.dart';

class AppLauncher {
  const AppLauncher({
    required DenialBridge bridge,
    DesktopExecParser execParser = const DesktopExecParser(),
  })  : _bridge = bridge,
        _execParser = execParser;

  final DenialBridge _bridge;
  final DesktopExecParser _execParser;

  static const Set<String> _genericIconNames = <String>{
    'application-default',
    'applications-system-symbolic',
    'network-wired',
  };

  List<String> expectedWindowAppIds(DesktopApp app) {
    final candidates = <String>{};

    void add(String? value) {
      final candidate = value?.trim();
      if (candidate != null && candidate.isNotEmpty) {
        candidates.add(candidate);
      }
    }

    add(app.id);
    if (app.id.toLowerCase().endsWith('.desktop')) {
      add(app.id.substring(0, app.id.length - '.desktop'.length));
    }
    add(app.startupWmClass);

    final icon = app.icon;
    if (icon != null && !_genericIconNames.contains(icon.toLowerCase())) {
      add(icon);
    }

    final argv = _execParser.parse(app.exec, app);
    final executable = _executableFrom(argv);
    if (executable != null) {
      final slash = executable.lastIndexOf('/');
      add(slash < 0 ? executable : executable.substring(slash + 1));
    }

    return List<String>.unmodifiable(candidates);
  }

  Future<bool> launch(DesktopApp app, {int? launchRequestId}) async {
    final argv = _execParser.parse(app.exec, app);
    if (argv.isEmpty) {
      return false;
    }

    return _bridge.launchApplication(
      argv,
      launchRequestId: launchRequestId,
    );
  }

  String? _executableFrom(List<String> argv) {
    if (argv.isEmpty) {
      return null;
    }
    var index = 0;
    final first = argv.first.split('/').last;
    if (first == 'env') {
      index = 1;
      while (index < argv.length) {
        final value = argv[index];
        if (!value.startsWith('-') && !value.contains('=')) {
          break;
        }
        index += 1;
      }
    }
    return index < argv.length ? argv[index] : null;
  }
}
