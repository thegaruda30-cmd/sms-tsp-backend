// This is a basic Flutter widget test for MyApp.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sms_tsp_system/main.dart';
import 'package:sms_tsp_system/providers/app_state.dart';

void main() {
  testWidgets('App initialization smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AppState()..initialize()),
        ],
        child: const MyApp(),
      ),
    );

    // Verify that the initializer screen shows the secure channel initialization text.
    expect(find.text('Initializing Secure Channel...'), findsOneWidget);
  });
}
