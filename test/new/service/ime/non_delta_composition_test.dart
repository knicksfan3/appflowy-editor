import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/non_delta_input_service.dart';
import 'package:appflowy_editor/src/editor/util/platform_extension.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../infra/testable_editor.dart';

// These are simulated IME updates, not real keyboard input. Mobile cases must
// also run on a device: PlatformExtension uses dart:io, not Theme.platform or
// debugDefaultTargetPlatformOverride.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'non-delta mobile composition',
    () {
      testWidgets('Korean syllable boundaries and composing deletion',
          (tester) async {
        final editor = await _startEditor(tester);
        for (var i = 0; i < 4; i++) {
          final prefix = '하' * i;
          await _update(tester, '$prefixㅎ', TextRange(start: i, end: i + 1));
          await _update(tester, '$prefix하', TextRange(start: i, end: i + 1));
        }
        expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '하하하하');

        // A software backspace first removes the vowel, then the consonant.
        await _update(tester, '하하하ㅎ', const TextRange(start: 3, end: 4));
        await _update(tester, '하하하', TextRange.empty);
        expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '하하하');
        await editor.dispose();
      });

      testWidgets('Japanese candidate replacement and a new composing segment',
          (tester) async {
        final editor = await _startEditor(tester);
        for (final text in ['に', 'にほ', 'にほん']) {
          await _update(tester, text, TextRange(start: 0, end: text.length));
        }
        // Candidate conversion changes the text length. The next segment may
        // start before a separate commit (non-text) update arrives.
        await _update(tester, '日本', const TextRange(start: 0, end: 2));
        await _update(tester, '日本ご', const TextRange(start: 2, end: 3));
        await _update(tester, '日本語', const TextRange(start: 2, end: 3));
        await _update(tester, '日本語', TextRange.empty);
        expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '日本語');
        await editor.dispose();
      });

      for (final text in ['하하', '日本', 'English']) {
        testWidgets('$text commit, newline, deletion and multiple undo/redo',
            (tester) async {
          final editor = await _startEditor(tester);
          await _update(tester, text, TextRange(start: 0, end: text.length));
          await _update(tester, text, TextRange.empty);
          final history = editor.editorState.undoManager;
          history.undoStack.last.seal();

          // This editor receives a newline as text, not performAction.
          await _send(tester, '$text\n', TextRange.empty);
          expect(editor.documentRootLen, 2);
          expect(editor.nodeAtPath([0])!.delta!.toPlainText(), text);
          expect(editor.nodeAtPath([1])!.delta!.toPlainText(), '');
          history.undoStack.last.seal();

          await editor.pressKey(key: LogicalKeyboardKey.backspace);
          expect(editor.documentRootLen, 1);
          expect(editor.nodeAtPath([0])!.delta!.toPlainText(), text);

          history.undo();
          await tester.pumpAndSettle();
          expect(editor.documentRootLen, 2);
          history.undo();
          await tester.pumpAndSettle();
          expect(editor.documentRootLen, 1);
          expect(history.redoStack.length, 2);

          history.redo();
          await tester.pumpAndSettle();
          expect(editor.documentRootLen, 2);
          // Protect 070d90d4 and the stack-length API from 59e154f7.
          expect(history.redoStack.length, 1);
          history.redo();
          await tester.pumpAndSettle();
          expect(editor.documentRootLen, 1);
          expect(editor.nodeAtPath([0])!.delta!.toPlainText(), text);
          expect(history.redoStack.length, 0);
          await editor.dispose();
        });
      }
    },
    skip: !PlatformExtension.isMobile,
  );

  testWidgets('hardware backspace resumes after composition-only commit',
      (tester) async {
    final editor = await _startEditor(tester);
    await _update(tester, '하', const TextRange(start: 0, end: 1));
    final keyboard = _keyboard(tester);
    expect(keyboard.enableIMEShortcuts, isFalse);

    // While composition is active, the editor must leave backspace to the IME.
    await editor.pressKey(key: LogicalKeyboardKey.backspace);
    expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '하');

    final selection = editor.selection;
    await _update(tester, '하', TextRange.empty);
    expect(editor.selection, selection);
    if (!PlatformExtension.isMobile) {
      // Desktop non-text handling refreshes the flag through selection changes.
      // Model the mobile stale flag so host CI also exercises its recovery.
      keyboard.enableIMEShortcuts = false;
    }
    await editor.pressKey(key: LogicalKeyboardKey.backspace);
    expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '');
    await editor.dispose();
  });

  testWidgets('composition recovery respects explicitly disabled shortcuts',
      (tester) async {
    final editor = await _startEditor(tester);
    await _update(tester, 'に', const TextRange(start: 0, end: 1));
    final keyboard = _keyboard(tester);
    keyboard.disableShortcuts();
    await _update(tester, 'に', TextRange.empty);
    await editor.pressKey(key: LogicalKeyboardKey.backspace);
    expect(editor.nodeAtPath([0])!.delta!.toPlainText(), 'に');
    keyboard.enableShortcuts();
    if (!PlatformExtension.isMobile) {
      keyboard.enableIMEShortcuts = false;
    }
    await editor.pressKey(key: LogicalKeyboardKey.backspace);
    expect(editor.nodeAtPath([0])!.delta!.toPlainText(), '');
    await editor.dispose();
  });
}

KeyboardServiceWidgetState _keyboard(WidgetTester tester) => tester
    .state<KeyboardServiceWidgetState>(find.byType(KeyboardServiceWidget));

Future<TestableEditor> _startEditor(WidgetTester tester) async {
  // IntegrationTestWidgetsFlutterBinding normally connects to the real IME.
  // These automated cases deliberately mock that channel to inspect feedback.
  tester.testTextInput.register();
  final editor = tester.editor..addEmptyParagraph();
  await editor.startTesting(inMobile: PlatformExtension.isMobile);
  await editor.updateSelection(Selection.collapsed(Position(path: [0])));
  return editor;
}

Future<void> _update(
  WidgetTester tester,
  String text,
  TextRange composing,
) async {
  tester.testTextInput.log.clear();
  final value = await _send(tester, text, composing);
  final input = _keyboard(tester).textInputService as NonDeltaTextInputService;
  expect(input.composingTextRange, composing);
  expect(input.currentTextEditingValue, value);
  // Sending a changed range back to the keyboard can interrupt composition.
  expect(
    tester.testTextInput.log
        .where((call) => call.method == 'TextInput.setEditingState'),
    isEmpty,
  );
}

Future<TextEditingValue> _send(
  WidgetTester tester,
  String text,
  TextRange composing,
) async {
  // The service prefixes its platform buffer with one sentinel space.
  final value = TextEditingValue(
    text: ' $text',
    selection: TextSelection.collapsed(offset: text.length + 1),
    composing: composing.isValid
        ? TextRange(start: composing.start + 1, end: composing.end + 1)
        : composing,
  );
  tester.testTextInput.updateEditingValue(value);
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pumpAndSettle();
  return value;
}
