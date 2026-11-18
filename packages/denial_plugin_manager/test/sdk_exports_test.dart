// The first test here resolves the whole SDK with the analyzer. On a builder
// that compiles beside the tests that takes longer than the default 30 s.
@Timeout(Duration(minutes: 3))
library;

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Resolve the SDK's actual public namespaces without starting Flutter. This
// guards against transitive exports leaking implementation or test machinery.
void main() {
  late AnalysisContextCollection contexts;
  final libraries = <String, LibraryElement>{};
  final root = p.normalize(p.absolute('../denial_flutter_sdk'));

  setUpAll(() {
    contexts = AnalysisContextCollection(includedPaths: [root]);
  });
  tearDownAll(() => contexts.dispose());

  Future<LibraryElement> library(String name) async {
    if (libraries[name] case final cached?) return cached;
    final result = await contexts
        .contextFor(root)
        .currentSession
        .getLibraryByUri('package:denial_flutter_sdk/$name.dart');
    expect(result, isA<LibraryElementResult>(), reason: name);
    return libraries[name] = (result as LibraryElementResult).element;
  }

  Future<void> namespace(
    String name, {
    List<String> available = const [],
    List<String> hidden = const [],
  }) async {
    final exports = (await library(name)).exportNamespace;
    for (final symbol in available) {
      expect(exports.get2(symbol), isNotNull, reason: '$name.$symbol');
    }
    for (final symbol in hidden) {
      expect(exports.get2(symbol), isNull, reason: '$name leaks $symbol');
    }
    expect(
      exports.definedNames2.keys.where((name) => name.endsWith('ForTesting')),
      isEmpty,
      reason: '$name exposes test-only hooks',
    );
  }

  test(
    'managed state exposes host operations without implementation helpers',
    () async {
      await namespace(
        'state',
        available: [
          'denialBridgeProvider',
          'shellControllerProvider',
          'ShellController',
          'ShellState',
          'displayLayoutProvider',
          'DisplayBrightnessState',
          'DesktopNotificationsState',
          'authenticationProvider',
        ],
        hidden: [
          'ClipboardHistoryLoader',
          'DesktopNotificationReducer',
          'DisplayBrightnessModel',
          'SystemTelemetryModel',
          'ShellWindowIndex',
          'ShellInputLayoutCoordinator',
          'ShellProfile',
          'shellProfileProvider',
          'reconcileAppAudioStreams',
          'updateAppAudioStreamVolume',
          'NotifierLifecycle',
          'lockStateRepositoryProvider',
        ],
      );
      final exports = (await library('state')).exportNamespace;
      final state = exports.get2('ShellState') as ClassElement;
      final controller = exports.get2('ShellController') as ClassElement;
      expect(
        state.fields.map((field) => field.name),
        isNot(contains('gestureDrag')),
      );
      expect(state.getGetter('quickSettingsDragProgress'), isNull);
      for (final method in ['goHome', 'openOverview', 'openEdgePanel']) {
        expect(controller.getMethod(method), isNull, reason: method);
      }
      await namespace(
        'input',
        available: ['InputLayoutSnapshot', 'InputWindowRegion'],
        hidden: ['ShellMetrics'],
      );
    },
  );

  test(
    'managed services exclude parsers, endpoints and worker protocols',
    () async {
      await namespace(
        'system_services',
        available: [
          'audioServiceProvider',
          'AudioService',
          'networkServiceProvider',
          'NetworkSnapshot',
          'bluetoothServiceProvider',
          'BluetoothSnapshot',
          'mediaPlayerServiceProvider',
          'StatusNotifierService',
        ],
        hidden: [
          'BackgroundWorker',
          'ShellWorker',
          'StatusNotifierWatcherEndpoint',
          'BluetoothAgentEndpoint',
          'IwdAgentEndpoint',
          'StatusNotifierUpdateEncoder',
          'MprisReadReconciliation',
          'parseProcStat',
          'parseLogindInhibitors',
          'readSysInt',
          'NetworkBackend',
          'LogindBackend',
          'IwdService',
        ],
      );
    },
  );

  test(
    'advanced integration remains available through focused libraries',
    () async {
      await namespace(
        'service_backends',
        available: [
          'NetworkBackend',
          'NetworkSnapshot',
          'BluetoothBackend',
          'LogindBackend',
          'LogindSnapshot',
          'UPowerBackend',
          'AuthenticationService',
          'SessionRuntimeBackend',
          'IwdService',
        ],
        hidden: [
          'IwdAgentEndpoint',
          'parseLogindInhibitors',
          'LockStateRepository',
        ],
      );
      await namespace(
        'lifecycle',
        available: ['NotifierLifecycle', 'DeferredEventDispatcher'],
      );
      await namespace(
        'workers',
        available: ['BackgroundWorker', 'serveBackgroundWorker'],
        hidden: ['ShellWorker', 'StatusNotifierProtocol'],
      );
      await namespace(
        'wire',
        available: [
          'DenialWireCodec',
          'AuthenticationProtocol',
          'SystemControlProtocol',
          'ClipboardHistoryProtocol',
          'DenialUiDevelopmentProtocol',
        ],
      );
    },
  );

  test('host bundle composes focused service capabilities', () async {
    const capabilities = [
      'ShellWindowServices',
      'ShellApplicationServices',
      'ShellDesktopServices',
      'ShellWorkspaceServices',
      'ShellTelemetryServices',
      'ShellAudioServices',
      'ShellConnectivityServices',
      'ShellMediaServices',
      'ShellPresentationServices',
      'ShellTrayServices',
    ];
    await namespace('services', available: ['ShellServices', ...capabilities]);
    final exports = (await library('services')).exportNamespace;
    final bundle = exports.get2('ShellServices') as ClassElement;
    expect(
      bundle.interfaces.map((type) => type.element.name),
      unorderedEquals(capabilities),
    );
    final windows = exports.get2('ShellWindowServices') as ClassElement;
    expect(windows.getMethod('activateWindow'), isNotNull);
    expect(windows.getGetter('battery'), isNull);
    final tray = exports.get2('ShellTrayServices') as ClassElement;
    expect(tray.getMethod('buildSystemTray'), isNotNull);
    expect(tray.getMethod('launchApplication'), isNull);
    final audio = exports.get2('ShellAudioServices') as ClassElement;
    expect(audio.getGetter('volume'), isNotNull);
    expect(audio.getMethod('commitVolume'), isNotNull);
    expect(audio.getMethod('activateWindow'), isNull);
    final connectivity =
        exports.get2('ShellConnectivityServices') as ClassElement;
    expect(connectivity.getGetter('connectedWifi'), isNotNull);
    expect(connectivity.getMethod('commitVolume'), isNull);
  });

  test(
    'shared controls expose presentation without host state or backends',
    () async {
      await namespace(
        'controls',
        available: ['RangeBar', 'VerticalRangeBar', 'WifiStatusIcon'],
        hidden: [
          'quickSettingsProvider',
          'networkConnectivityProvider',
          'NetworkBackend',
          'ShellServices',
          'ShadeReferenceGeometry',
        ],
      );
      expect(
        (await library('controls')).exportNamespace.definedNames2.keys,
        unorderedEquals(['RangeBar', 'VerticalRangeBar', 'WifiStatusIcon']),
      );
    },
  );

  test(
    'typed platform and value models do not re-export backend internals',
    () async {
      await namespace(
        'platform',
        available: [
          'DenialBridge',
          'DenialOutputControlException',
          'DenialAudioState',
          'AuthenticationPromptStyle',
        ],
        hidden: [
          'AuthenticationProtocol',
          'SystemControlProtocol',
          'collectBoundedBytes',
          'decodeBoundedUtf8Lines',
          'BridgeContext',
          'BridgePlatformTransport',
          'BridgeControlClient',
          'BridgeWindowsClient',
          'BridgeSettingsDocumentClient',
          'BridgeEventsClient',
        ],
      );
      await namespace(
        'models',
        available: ['DenialWindow', 'LogindSnapshot'],
        hidden: ['LogindBackend'],
      );
      await namespace(
        'shell',
        available: [
          'runDenialShell',
          'ShellActionsBinding',
          'ShellOverlayHost',
          'ShellWindowsBuilder',
          'ShellPrimaryWindow',
          'ShellWindowActions',
        ],
        hidden: ['DeferredEventDispatcher'],
      );
      await namespace(
        'theme',
        available: ['ShellTheme', 'ShellFontCatalog'],
        hidden: ['parseWindowsAnimatedCursor', 'normalizeShellFontFamilies'],
      );
    },
  );
}
