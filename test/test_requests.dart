import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/services/api_service.dart';
import '../lib/models/request.dart';

void main() {
  test('API request parse test', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    print('Starting API request parse test...');
  final api = ApiService();
  print('API Base URL: ${api.activeBaseUrl}');
  
  // Try login
  final bool loggedIn = await api.login('admin', 'Admin@1234');
  print('Logged in successfully: $loggedIn');
  if (!loggedIn) {
    print('Failed to log in.');
    return;
  }
  
  print('Token: ${api.token}');
  
  // Try getRequests
  try {
    final requests = await api.getRequests();
    print('Successfully fetched ${requests.length} requests.');
    if (requests.isNotEmpty) {
      print('First request ID: ${requests.first.id}');
      print('First request status: ${requests.first.status}');
    }
  } catch (e, stack) {
    print('Error fetching requests: $e');
    print(stack);
  }
  });
}
