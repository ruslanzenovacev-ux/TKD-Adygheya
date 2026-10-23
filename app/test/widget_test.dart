import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tkd_app/main.dart';

void main() {
  testWidgets('без входа показывается экран входа по почте', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const TkdApp());
    await tester.pumpAndSettle();
    expect(find.text('Получить код'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Электронная почта'), findsOneWidget);
  });
}
