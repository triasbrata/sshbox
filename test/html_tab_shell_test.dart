import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sshbox/src/data/host_repository.dart';
import 'package:sshbox/src/data/secret_store.dart';
import 'package:sshbox/src/files/file_browser.dart';
import 'package:sshbox/src/models/host_profile.dart';
import 'package:sshbox/src/session/session_manager.dart';
import 'package:sshbox/src/session/terminal_session.dart';
import 'package:sshbox/src/ui/tabs_shell.dart';
import 'package:sshbox/src/ui/tui.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_file_browser.dart';
import 'fake_web_view.dart';

class _NoSecrets implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String? value) async {}

  @override
  Future<void> purgeHost(String hostId) async {}
}

class _Launcher extends UrlLauncherPlatform {
  final tried = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    tried.add(url);
    return true;
  }
}

/// A connected host with a file tree and nothing else.
class _Shell implements SessionTransport, TerminalSession, FileBrowseCapable {
  _Shell(this.files);
  final FakeFileBrowser files;

  @override
  Future<TerminalSession> connect({
    required HostProfile host,
    required SecretStore secrets,
    required int columns,
    required int rows,
    bool shell = true,
    Map<String, String> environment = const {},
    Future<Map<String, String>> Function(ForwardCapable host)? beforeShell,
  }) async => this;

  @override
  final status = ValueNotifier(SessionStatus.connected);

  @override
  Stream<String> get output => const Stream.empty();

  @override
  String? get failure => null;

  @override
  void send(String data) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<void> dispose() async {}

  @override
  FileBrowser openFileBrowser() => files;
}

const _box = HostProfile(
  id: 'box',
  label: 'box',
  host: 'box.example',
  username: 'me',
);

void main() {
  late SessionManager manager;
  late FakeFileBrowser files;
  late FakeWebViewPlatform platform;
  late _Launcher launcher;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    WebViewPlatform.instance = platform = FakeWebViewPlatform();
    UrlLauncherPlatform.instance = launcher = _Launcher();
    files = FakeFileBrowser();
    await files.writeText('/home/me/site/page.html', '<h1>x</h1>');
    manager = SessionManager();
    manager.open(_box, transport: (_, _) => _Shell(files));
  });

  tearDown(() async {
    await manager.closeAll();
    debugDefaultTargetPlatformOverride = null;
    await manager.closeAll();
  });

  Future<void> pumpTabs(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final session in manager.sessions) {
      await session.connect(secrets: _NoSecrets());
    }
    await tester.pumpWidget(
      MaterialApp(
        home: TabsShell(
          repository: HostRepository(_NoSecrets()),
          secrets: _NoSecrets(),
          sessions: manager,
          onOpenHost: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> leave(WidgetTester tester) async {
    // The tree stays up, as the other shell tests leave it; the editor's
    // cursor timer cannot be disposed under a fake clock.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(seconds: 10));
    debugDefaultTargetPlatformOverride = null;
  }

  Future<void> settleSockets(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  Future<void> openFileTab(WidgetTester tester) async {
    await pumpTabs(tester);
    manager.openFile(manager.sessions.single.id, '/home/me/site/page.html');
    await tester.pump();
    await tester.pump();
  }

  testWidgets('where the system has a web view, the button opens a tab that '
      'loads the file from a loopback site', (tester) async {
    await openFileTab(tester);
    await tester.tap(find.byTooltip('Open in browser tab'));
    await settleSockets(tester);

    final tab = manager.sessions.single.webTabs.single;
    expect(tab.htmlPath, '/home/me/site/page.html');
    final loaded = platform.view.loaded.single;
    expect(loaded.host, '127.0.0.1');
    expect(loaded.pathSegments.last, 'page.html');
    expect(launcher.tried, isEmpty);

    // Closing the tab stops the site.
    manager.closeWeb(manager.sessions.single.id, tab);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await leave(tester);
  });

  testWidgets('where it has none, the file opens in the browser, said so, '
      'and no tab opens', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await openFileTab(tester);
    await tester.tap(find.byTooltip('Open in browser tab'));
    await settleSockets(tester);

    expect(manager.sessions.single.webTabs, isEmpty);
    expect(find.text('OPENS OUTSIDE JEANSH'), findsOneWidget);
    expect(
      find.textContaining('page.html is shown in your browser'),
      findsOneWidget,
    );
    expect(launcher.tried.single, startsWith('http://127.0.0.1:'));
    expect(launcher.tried.single, endsWith('/page.html'));

    await tester.tap(_button('Open again'));
    await tester.pump();
    expect(launcher.tried.length, 2);

    await tester.tap(_button('Done'));
    await settleSockets(tester);
    expect(find.text('OPENS OUTSIDE JEANSH'), findsNothing);
    await leave(tester);
  });
}

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is TuiButton && w.label == label);
