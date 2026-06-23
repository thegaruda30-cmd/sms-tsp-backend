import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sms_tsp_system/providers/app_state.dart';
import 'package:sms_tsp_system/services/api_service.dart';

import 'package:sms_tsp_system/screens/officer/officer_dashboard.dart';
import 'package:sms_tsp_system/models/user.dart';
import 'package:sms_tsp_system/models/user_role.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Layout test for OfficerDashboard on small screen', (WidgetTester tester) async {
    final appState = AppState();
    
    final dummyOfficer = User(
      id: 2,
      username: 'officer_ranjeet',
      email: 'ranjeet@police.gov.in',
      role: UserRole.OFFICER,
      directForwardAllowed: true,
      bypassDailyLimit: false,
      bypassRequested: false,
      extraRequestsLimit: 0,
      bypassExpiryDate: null,
      isBypassActive: false,
      firstName: 'Ranjeet',
      lastName: 'Kumar',
    );

    // Set screen size to mobile portrait
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1.0;

    ApiService().currentUser = dummyOfficer;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: appState,
        child: const MaterialApp(
          home: Scaffold(
            body: OfficerDashboard(),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
  });
}
