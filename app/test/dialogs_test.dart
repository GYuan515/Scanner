import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:doc_scanner/ui/library_actions.dart';

void main() {
  // Regression: the controller used to be disposed as soon as showDialog
  // returned, while the dialog was still animating out. That crashed with
  // "TextEditingController was used after being disposed" and then
  // `_dependents.isEmpty` (seen on device when creating a folder).
  Future<String?> runPrompt(WidgetTester tester, Future<void> Function() act) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await promptText(context, title: '新建文件夹', initial: '旧名'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await act();
    // Run the whole exit animation; the bug fired during these frames.
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    return result;
  }

  testWidgets('confirm returns trimmed text and survives the exit animation', (tester) async {
    final r = await runPrompt(tester, () async {
      await tester.enterText(find.byType(TextField), '  发票  ');
      await tester.tap(find.text('确定'));
    });
    expect(r, '发票');
    expect(tester.takeException(), isNull);
  });

  testWidgets('submitting from the keyboard works too', (tester) async {
    final r = await runPrompt(tester, () async {
      await tester.enterText(find.byType(TextField), '合同');
      await tester.testTextInput.receiveAction(TextInputAction.done);
    });
    expect(r, '合同');
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel and empty input return null', (tester) async {
    expect(await runPrompt(tester, () => tester.tap(find.text('取消'))), isNull);
    final empty = await runPrompt(tester, () async {
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('确定'));
    });
    expect(empty, isNull);
    expect(tester.takeException(), isNull);
  });
}
