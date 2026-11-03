/// Application catalog, launching, local windows and managed launcher state.
/// Desktop-entry utilities support command validation without launching apps.
library;

export 'package:denial_sdk/applications.dart' show DesktopApp;

export 'src/launcher/controllers/application_recents_controller.dart'
    show
        ApplicationRecentsController,
        applicationRecentsProvider,
        applicationRecentsStoreProvider,
        desktopApplicationRecentId,
        localApplicationRecentId;
export 'src/launcher/controllers/home_grid_controller.dart'
    show
        HomeGridController,
        HomeGridState,
        appLauncherProvider,
        desktopAppsRepositoryProvider,
        homeClockProvider,
        homeGridControllerProvider,
        homeLayoutRepositoryProvider;
export 'src/launcher/controllers/home_grid_layout.dart' show HomeGridLayout;
export 'src/launcher/launcher_providers.dart'
    show homeTitleProvider, runtimePathsProvider, screenPowerServiceProvider;
export 'src/launcher/models/home_clock_info.dart'
    show HomeClockInfo, HomePowerStatus, HomeThermalReading;
export 'src/launcher/models/home_grid_item.dart'
    show HomeGridItem, HomeGridItemType, HomeLayoutSlot, HomeOrientation;
export 'src/launcher/repositories/application_recents_repository.dart'
    show
        ApplicationRecentsRepository,
        ApplicationRecentsStore,
        applicationRecentEntryLimit;
export 'src/launcher/repositories/desktop_apps_repository.dart'
    show DesktopAppsRepository, DesktopAppsWatcher;
export 'src/launcher/repositories/home_layout_repository.dart'
    show HomeLayoutRepository, HomeSavedLayouts;
export 'src/launcher/runtime_paths.dart' show RuntimePaths;
export 'src/launcher/services/app_launcher.dart' show AppLauncher;
export 'src/launcher/services/desktop_exec_parser.dart' show DesktopExecParser;
export 'src/launcher/services/screen_power_service.dart'
    show ScreenPowerService;
export 'src/local_apps/local_flutter_application.dart'
    show
        LocalFlutterApplication,
        LocalFlutterApplicationBuilder,
        LocalFlutterApplicationCategoriesBuilder,
        LocalFlutterApplicationLauncher,
        LocalFlutterApplicationRegistry,
        LocalFlutterApplicationTitleBuilder,
        LocalFlutterWindowHandle,
        localFlutterApplicationLauncherProvider,
        localFlutterApplicationRegistryProvider,
        localFlutterApplicationsProvider;
export 'src/local_apps/local_flutter_window_host.dart'
    show LocalFlutterWindowHost, LocalFlutterWindowHostKey;
