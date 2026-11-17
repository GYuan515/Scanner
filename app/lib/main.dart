import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app_state.dart';
import 'error_log.dart';
import 'data/db.dart';
import 'data/page_store.dart';
import 'ui/camera_screen.dart';
import 'ui/code_scan_screen.dart';
import 'ui/collection_screens.dart';
import 'ui/diagnostics_screen.dart';
import 'ui/document_screen.dart';
import 'ui/home_screen.dart';
import 'ui/pdf_toolbox_screen.dart';
import 'ui/settings_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ErrorLog.install();
  // PDFium is used to render imported PDFs into pages.
  await pdfrxFlutterInitialize();
  final db = AppDatabase();
  final store = await PageStore.open(db);
  // Recycle-bin entries older than 30 days; failure must not block startup.
  unawaited(store.purgeExpiredTrash().catchError((Object e, StackTrace st) {
    ErrorLog.instance?.write('purgeExpiredTrash', '$e', st);
    return 0;
  }));
  final container = ProviderContainer(overrides: [
    dbProvider.overrideWithValue(db),
    storeProvider.overrideWithValue(store),
  ]);
  // Background OCR: on unless the user turned it off in settings.
  final queue = container.read(ocrQueueProvider)..auto = await db.getSetting(ocrAutoKey) != '0';
  queue.start();
  runApp(UncontrolledProviderScope(container: container, child: const ScannerApp()));
}

final _router = GoRouter(routes: [
  GoRoute(path: '/', builder: (_, _) => const LibraryScreen()),
  GoRoute(path: '/folder/:id', builder: (_, s) => LibraryScreen(folderId: int.parse(s.pathParameters['id']!))),
  GoRoute(path: '/recent', builder: (_, _) => const RecentScreen()),
  GoRoute(path: '/trash', builder: (_, _) => const TrashScreen()),
  GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
  GoRoute(
    path: '/scan',
    // ?doc=<id> adds pages to an existing document; &at=<index> inserts
    // them at that position instead of appending. ?folder=<id> puts a new
    // document into that folder.
    builder: (_, s) => CameraScreen(
      appendTo: int.tryParse(s.uri.queryParameters['doc'] ?? ''),
      insertAt: int.tryParse(s.uri.queryParameters['at'] ?? ''),
      folderId: int.tryParse(s.uri.queryParameters['folder'] ?? ''),
    ),
  ),
  GoRoute(path: '/diagnostics', builder: (_, _) => const DiagnosticsScreen()),
  GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
  GoRoute(path: '/codes', builder: (_, _) => const CodeScanScreen()),
  GoRoute(path: '/pdf-tools', builder: (_, _) => const PdfToolboxScreen()),
  GoRoute(path: '/doc/:id', builder: (_, s) => DocumentScreen(docId: int.parse(s.pathParameters['id']!))),
]);

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1A73E8);
    return MaterialApp.router(
      title: '扫描',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: seed, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark, useMaterial3: true),
      routerConfig: _router,
    );
  }
}
