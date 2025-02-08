import 'dart:convert';
import 'dart:io' as io;

import 'package:kwin/kwin.dart';

import '../../../logs/logs.dart';
import '../native_platform.dart';
import '../process/models/process.dart';
import '../typedefs.dart';
import '../window.dart';
import 'dbus/nyrna_dbus.dart';
import 'session_type.dart';

export 'flatpak.dart';
export 'session_type.dart';

/// System-level or non-app executables. Nyrna shouldn't show these.
const List<String> _filteredWindows = [
  'nyrna',
  // Remove any instances of plasmashell, which is the KDE desktop.
  // It appears to show up for each monitor and virtual desktop.
  'plasmashell',
  'xwaylandvideobridge',
];

/// Interact with the native Linux operating system.
class Linux implements NativePlatform {
  /// Name of the KWin script that fetches info when running KDE Wayland.
  static const String _kdeWaylandScriptName = 'nyrna_wayland';

  /// Path to the KWin script that fetches info when running KDE Wayland.
  ///
  /// The path is an argument to allow for dependency injection in tests.
  final String _kdeWaylandScriptPath;

  final KWin _kwin;
  final NyrnaDbus _nyrnaDbus;
  final RunFunction _run;

  Linux._(
    this._kdeWaylandScriptPath,
    this._kwin,
    this._nyrnaDbus,
    this._run,
  );

  static Future<Linux> initialize(
    RunFunction run, [
    String kdeWaylandScriptPath = '',
    KWin? kwin, // Allows overriding for testing.
    NyrnaDbus? nyrnaDbus, // Allows overriding for testing.
  ]) async {
    final dbusService = nyrnaDbus ?? await NyrnaDbus.initialize();
    final kwinService = kwin ?? KWin();
    final linux = Linux._(kdeWaylandScriptPath, kwinService, dbusService, run);
    final session = await linux.sessionType();
    if (session.displayProtocol == DisplayProtocol.wayland &&
        session.environment == DesktopEnvironment.kde) {
      await linux._loadKdeWaylandScript();
    }

    return linux;
  }

  Future<void> _loadKdeWaylandScript() async {
    log.i('Loading KWin script for KDE Wayland. Path: $_kdeWaylandScriptPath');

    await _kwin.loadScript(_kdeWaylandScriptPath, _kdeWaylandScriptName);

    // _kwin.scriptOutput.listen((event) {
    //   log.t('KWin script output: $event');
    // });

    // print script output, but filter for online lines containing 'Nyrna:'
    _kwin.scriptOutput.where((event) => event.contains('Nyrna:')).listen((event) {
      log.t('KWin script output: $event');
    });

    // Wait for the script to be loaded. Otherwise when the window loads it looks briefly
    // as though no windows were found.
    await Future.delayed(const Duration(seconds: 1));
  }

  int? _desktop;

  // Active virtual desktop as reported by wmctrl.
  @override
  Future<int> currentDesktop() async {
    final result = await _run('wmctrl', ['-d']);
    final lines = result.stdout.toString().split('\n');
    for (var line in lines) {
      if (line.contains('*')) _desktop = int.tryParse(line[0]);
    }
    _desktop ??= 0;
    return _desktop ?? 0;
  }

  // Gets all open windows as reported by wmctrl.
  @override
  Future<List<Window>> windows({bool showHidden = false}) async {
    final session = await sessionType();

    switch (session.displayProtocol) {
      case DisplayProtocol.wayland:
        return await _getWindowsWayland(showHidden);
      case DisplayProtocol.x11:
        return await _getWindowsX11(showHidden);
      default:
        return Future.error('Unknown session type: $sessionType');
    }
  }

  Future<List<Window>> _getWindowsWayland(bool showHidden) async {
    final session = await sessionType();

    if (session.displayProtocol != DisplayProtocol.wayland) {
      throw Future.error('Expected Wayland session but got ${session.displayProtocol}');
    }

    switch (session.environment) {
      case DesktopEnvironment.kde:
        return await _getWindowsKdeWayland(showHidden);
      case DesktopEnvironment.gnome:
        throw UnimplementedError();
      default:
        throw Future.error('Unknown desktop environment: ${session.environment}');
    }
  }

  Future<List<Window>> _getWindowsKdeWayland(bool showHidden) async {
    if (_nyrnaDbus.windowsJson.isEmpty) {
      log.w('No windows found from KDE Wayland');
      return [];
    }

    final windowsJson = jsonDecode(_nyrnaDbus.windowsJson);
    final windows = <Window>[];

    for (var window in windowsJson) {
      final onCurrentDesktop = window['onCurrentDesktop'] == true;
      if (!onCurrentDesktop && !showHidden) continue;

      final windowId = window['internalId'];
      final windowTitle = window['caption'];
      final pid = window['pid'];
      final executable = await _getExecutableName(pid);
      if (_filteredWindows.contains(executable)) continue;

      final process = Process(
        pid: pid,
        executable: executable,
        status: ProcessStatus.unknown,
      );

      windows.add(Window(
        id: windowId,
        process: process,
        title: windowTitle,
      ));
    }

    log.i('Windows from KDE Wayland: found ${windows.length} windows');

    return windows;
  }

  Future<List<Window>> _getWindowsX11(bool showHidden) async {
    await currentDesktop();

    final wmctrlOutput = await _run('bash', ['-c', 'wmctrl -lp']);

    // Each line from wmctrl will be something like:
    // 0x03600041  1 1459   SHODAN Inbox - Unified Folders - Mozilla Thunderbird
    // windowId, desktopId, pid, user, window title
    final lines = wmctrlOutput.stdout.toString().split('\n');

    final windows = <Window>[];

    for (var line in lines) {
      final window = await _buildWindow(line, showHidden);
      if (window != null) windows.add(window);
    }

    return windows;
  }

  /// wmctrl reports a window's desktop number as -1 if it is "sticky".
  /// For example, if using GNOME's "Workspaces on primary display only"
  /// preference every window on secondary displays will have "desktop: -1";
  static const _kStickyWindowIdentifier = -1;

  /// Takes a line of output from wmctrl and if valid returns a [Window].
  Future<Window?> _buildWindow(String wmctrlLine, bool showHidden) async {
    final parts = wmctrlLine.split(' ');
    parts.removeWhere((part) => part == ''); // Happens with multiple spaces.

    if (parts.length < 2) return null;

    // Which virtual desktop this window is on.
    final windowDesktop = int.tryParse(parts[1]);
    final windowOnCurrentDesktop =
        (windowDesktop == _desktop || windowDesktop == _kStickyWindowIdentifier);
    if (!windowOnCurrentDesktop && !showHidden) return null;

    final pid = int.tryParse(parts[2]);
    final id = int.tryParse(parts[0]);
    if ((pid == null) || (id == null)) return null;

    final executable = await _getExecutableName(pid);
    if (_filteredWindows.contains(executable)) return null;

    final process = Process(
      executable: executable,
      pid: pid,
      status: ProcessStatus.unknown,
    );
    final title = parts.sublist(4).join(' ');

    return Window(id: '$id', process: process, title: title);
  }

  Future<String> _getExecutableName(int pid) async {
    final result = await _run('readlink', ['/proc/$pid/exe']);
    final executable = result.stdout.toString().split('/').last.trim();
    return executable;
  }

  @override
  Future<Window> activeWindow() async {
    final windowId = await _activeWindowId();
    if (windowId == '0') throw (Exception('No window id'));

    final pid = await _activeWindowPid(windowId);
    if (pid == 0) throw (Exception('No pid'));

    final executable = await _getExecutableName(pid);
    final process = Process(
      pid: pid,
      executable: executable,
      status: ProcessStatus.unknown,
    );
    final windowTitle = await _activeWindowTitle();

    return Window(
      id: windowId,
      process: process,
      title: windowTitle,
    );
  }

  // Returns the unique hex ID of the active window as reported by xdotool.
  Future<String> _activeWindowId() async {
    final result = await _run('xdotool', ['getactivewindow']);
    final windowId = result.stdout.toString().trim();
    return windowId;
  }

  Future<int> _activeWindowPid(String windowId) async {
    final result = await _run(
      'xdotool',
      ['getwindowpid', windowId],
    );
    final pid = int.tryParse(result.stdout.toString().trim());
    return pid ?? 0;
  }

  Future<String> _activeWindowTitle() async {
    final result = await _run(
      'xdotool',
      ['getactivewindow getwindowname'],
    );
    return result.stdout.toString().trim();
  }

  // Verify wmctrl and xdotool are present on the system.
  @override
  Future<bool> checkDependencies() async {
    final xdotoolResult = await _run('bash', [
      '-c',
      'command -v xdotool >/dev/null 2>&1 || { echo >&2 "xdotool is required but it\'s not installed."; exit 1; }'
    ]);

    final wmctrlResult = await _run('bash', [
      '-c',
      'command -v wmctrl >/dev/null 2>&1 || { echo >&2 "wmctrl is required but it\'s not installed."; exit 1; }'
    ]);

    final xdotoolAvailable = xdotoolResult.stderr.toString().trim() == '';
    final wmctrlAvailable = wmctrlResult.stderr.toString().trim() == '';
    final dependenciesAvailable = xdotoolAvailable && wmctrlAvailable;

    if (!dependenciesAvailable) {
      log.e(
        '''
Dependency check failed!
xdotool available: $xdotoolAvailable
wmctrl available: $wmctrlAvailable
Make sure these are installed on your host system.''',
      );
    }

    return dependenciesAvailable;
  }

  SessionType? _sessionType;

  /// Returns the current session type.
  Future<SessionType> sessionType() async {
    if (_sessionType != null) return _sessionType!;

    final displayProtocolEnv = io.Platform.environment['XDG_SESSION_TYPE'];
    if (displayProtocolEnv == null || displayProtocolEnv.isEmpty) {
      log.e('XDG_SESSION_TYPE is not set');
      return Future.error('XDG_SESSION_TYPE is not set');
    }

    final displayProtocol = DisplayProtocol.fromString(displayProtocolEnv);

    final environmentEnv = io.Platform.environment['XDG_CURRENT_DESKTOP'];
    if (environmentEnv == null || environmentEnv.isEmpty) {
      log.e('XDG_CURRENT_DESKTOP is not set');
      return Future.error('XDG_CURRENT_DESKTOP is not set');
    }

    final environment = DesktopEnvironment.fromString(environmentEnv);
    _sessionType = SessionType(
      displayProtocol: displayProtocol,
      environment: environment,
    );

    return _sessionType!;
  }

  @override
  Future<bool> minimizeWindow(String windowId) async {
    log.i('Minimizing window with id $windowId');
    final session = await sessionType();

    switch (session.displayProtocol) {
      case DisplayProtocol.wayland:
        switch (session.environment) {
          case DesktopEnvironment.kde:
            return await _minimizeWindowWaylandKDE(windowId);
          case DesktopEnvironment.gnome:
            return Future.error('Minimize not implemented for GNOME Wayland');
          default:
            return Future.error('Unknown desktop environment: ${session.environment}');
        }
      case DisplayProtocol.x11:
        return await _minimizeWindowX11(windowId);
      default:
        return Future.error('Unknown session type: $session.displayProtocol');
    }
  }

  Future<bool> _minimizeWindowX11(String windowId) async {
    final result = await _run(
      'wmctrl',
      ['-i', '-r', windowId, '-b', 'add,hidden'],
    );
    return (result.stderr == '') ? true : false;
  }

  static const String kwinMinimizeRestoreScript = '''
function print(str) {
    console.info('Nyrna: ' + str);
}

let windows = workspace.windowList();
let targetWindowId = "%windowId%";
let targetWindow = windows.find(w => w.internalId.toString() === targetWindowId);

if (!targetWindow) {
    print('Window with id ' + targetWindowId + ' not found');
}

let shouldMinimize = %minimize%;
targetWindow.minimized = shouldMinimize;

print('Window with id ' + targetWindowId + ' ' + (shouldMinimize ? 'minimized' : 'restored'));

if (!shouldMinimize) {
    workspace.activeWindow = targetWindow;
}
''';

  Future<bool> _minimizeWindowWaylandKDE(String windowId) async {
    // Create a javascript file in the tmp directory, which will be populated with the
    // script to minimize the window.
    final scriptFile = io.File('${io.Directory.systemTemp.path}/nyrna_minimize.js');
    await scriptFile.writeAsString(
      kwinMinimizeRestoreScript
          .replaceAll('%windowId%', windowId)
          .replaceAll('%minimize%', 'true'),
    );

    // Run the script with kwin.
    await _kwin.loadScript(scriptFile.path, 'nyrna_minimize');
    return true;
  }

  @override
  Future<bool> restoreWindow(String windowId) async {
    log.i('Restoring window with id $windowId');
    final session = await sessionType();

    switch (session.displayProtocol) {
      case DisplayProtocol.wayland:
        switch (session.environment) {
          case DesktopEnvironment.kde:
            return await _restoreWindowWaylandKDE(windowId);
          case DesktopEnvironment.gnome:
            return Future.error('Restore not implemented for GNOME Wayland');
          default:
            return Future.error('Unknown desktop environment: ${session.environment}');
        }
      case DisplayProtocol.x11:
        return await _restoreWindowX11(windowId);
      default:
        return Future.error('Unknown session type: $session.displayProtocol');
    }
  }

  Future<bool> _restoreWindowX11(String windowId) async {
    final result = await _run(
      'wmctrl',
      ['-i', '-r', windowId, '-b', 'remove,hidden'],
    );
    return (result.stderr == '') ? true : false;
  }

  Future<bool> _restoreWindowWaylandKDE(String windowId) async {
    // Create a javascript file in the tmp directory, which will be populated with the
    // script to restore the window.
    final scriptFile = io.File('${io.Directory.systemTemp.path}/nyrna_restore.js');
    await scriptFile.writeAsString(
      kwinMinimizeRestoreScript
          .replaceAll('%windowId%', windowId)
          .replaceAll('%minimize%', 'false'),
    );

    // Run the script with kwin.
    await _kwin.loadScript(scriptFile.path, 'nyrna_restore');
    return true;
  }

  @override
  Future<void> dispose() async {
    await _kwin.unloadScript(_kdeWaylandScriptName);
    await _kwin.dispose();
    await _nyrnaDbus.dispose();
  }
}
