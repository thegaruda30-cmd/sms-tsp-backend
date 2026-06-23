import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../models/tsp_provider.dart';
import '../models/request.dart';
import '../models/activity_log.dart';
import '../models/chat_message.dart';
import '../models/tsp_response.dart';
import '../models/tsp_setting.dart';

class ApiService {
  static const String _configuredBaseUrl = String.fromEnvironment('API_BASE_URL');
  String? _activeBaseUrl;
  String? _token;
  User? _currentUser;

  User? get currentUser => _currentUser;
  set currentUser(User? user) => _currentUser = user;
  String? get token => _token;

  // Singleton pattern
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  Future<List<String>> getBaseUrlCandidates() async {
    final candidates = <String>[];

    try {
      final prefs = await SharedPreferences.getInstance();
      final customUrl = prefs.getString('custom_api_url');
      if (customUrl != null && customUrl.trim().isNotEmpty) {
        candidates.add(customUrl.trim());
      }
    } catch (_) {}

    // Add production server as primary default candidate
    candidates.add('https://sms-tsp-backend.onrender.com/api');

    if (_configuredBaseUrl.isNotEmpty) {
      candidates.add(_configuredBaseUrl);
    }

    if (kIsWeb) {
      candidates.add('http://127.0.0.1:8000/api');
      candidates.add('http://localhost:8000/api');
    } else if (defaultTargetPlatform == TargetPlatform.android) {
      candidates.add('http://192.168.1.11:8000/api'); // Current user PC IP
      candidates.add('http://192.168.1.12:8000/api'); // Current local IP of PC
      candidates.add('http://192.168.1.16:8000/api'); // PC LAN IP — real device on same WiFi
      candidates.add('http://10.0.2.2:8000/api');     // Android emulator localhost
      candidates.add('http://127.0.0.1:8000/api');
      candidates.add('http://localhost:8000/api');
    } else {
      candidates.add('http://127.0.0.1:8000/api');
      candidates.add('http://localhost:8000/api');
      candidates.add('http://10.0.2.2:8000/api');
    }

    return candidates.toSet().toList();
  }

  String get _baseUrl => 'https://sms-tsp-backend.onrender.com/api';
  String get activeBaseUrl => _baseUrl;

  Future<void> wakeUpBackend() async {
    try {
      // Fire-and-forget request to wake up Render container in background
      http.get(Uri.parse('$_baseUrl/login/')).timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  Future<void> init() async {
    wakeUpBackend(); // Start waking up Render in the background

    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    final userJson = prefs.getString('current_user');
    if (userJson != null) {
      _currentUser = User.fromJson(jsonDecode(userJson));
    }
  }

  Map<String, String> _getHeaders() {
    final Map<String, String> headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    };
    if (_token != null) {
      headers['Authorization'] = 'Token $_token';
    }
    return headers;
  }

  // Auth methods
  Future<bool> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/login/'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      ).timeout(const Duration(seconds: 75));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _token = data['token'];
        _currentUser = User.fromJson(data['user']);

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', _token!);
        await prefs.setString('current_user', jsonEncode(data['user']));
        return true;
      }
      // Return false (bad credentials) — don't throw, just fail gracefully
      return false;
    } catch (e) {
      // Network error — rethrow so the UI can show what went wrong
      rethrow;
    }
  }

  Future<void> logout() async {
    _token = null;
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('current_user');
  }

  Future<User?> getProfile() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/profile/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        _currentUser = User.fromJson(data);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('current_user', jsonEncode(data));
        return _currentUser;
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // TSP Providers
  Future<List<TSPProvider>> getTSPs() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/tsps/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => TSPProvider.fromJson(json)).toList();
      }
    } catch (e) {
      // Log or handle error
    }
    return [];
  }

  Future<TSPProvider?> createTSP(Map<String, dynamic> data) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/tsps/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 201) {
        return TSPProvider.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<TSPProvider?> updateTSP(int id, Map<String, dynamic> data) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/tsps/$id/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 200) {
        return TSPProvider.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<bool> deleteTSP(int id) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/tsps/$id/'),
        headers: _getHeaders(),
      );
      return response.statusCode == 204;
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<TSPProvider?> setDefaultTSP(int id) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/tsps/$id/set-default/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return TSPProvider.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // Requests
  Future<List<RequestModel>> getRequests({String? status, int? tspId, String? search}) async {
    try {
      String query = '';
      final List<String> params = [];
      if (status != null && status.isNotEmpty) params.add('status=$status');
      if (tspId != null) params.add('tsp=$tspId');
      if (search != null && search.isNotEmpty) params.add('search=$search');
      if (params.isNotEmpty) query = '?${params.join('&')}';

      final response = await http.get(Uri.parse('$_baseUrl/requests/$query'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => RequestModel.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<RequestModel?> createRequest(String mobileNumber, int tspId, {required String remarks, String stationName = '', String crNo = '', String subject = '', String message = ''}) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'mobile_number': mobileNumber,
          'tsp': tspId,
          'remarks': remarks,
          'station_name': stationName,
          'cr_no': crNo,
          'subject': subject,
          'message': message,
        }),
      );

      if (response.statusCode == 201) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // Admin Actions
  Future<RequestModel?> adminReview(int requestId, String action, String remarks) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/admin-review/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'action': action, // 'APPROVE' or 'REJECT'
          'remarks': remarks,
        }),
      );

      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<RequestModel?> forwardToTsp(int requestId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/forward-to-tsp/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<RequestModel?> adminComplete(int requestId, String remarks) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/admin-complete/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'remarks': remarks,
        }),
      );

      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // TSP Actions
  Future<RequestModel?> tspAccept(int requestId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/tsp-accept/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<RequestModel?> tspReject(int requestId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/tsp-reject/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<RequestModel?> tspRespond(int requestId, String details, {String notes = ''}) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/tsp-respond/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'details': details,
          'notes': notes,
        }),
      );

      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  /// Log an inbound TSP SMS - TSP operator sent an SMS to our configured inbound number
  Future<RequestModel?> tspSmsResponse(int requestId, String fromNumber, String inboundNumber, String smsBody) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/tsp-sms-response/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'from_number': fromNumber,
          'inbound_number': inboundNumber,
          'sms_body': smsBody,
        }),
      );
      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle offline fallback
    }
    return null;
  }

  // Stats View
  Future<Map<String, dynamic>?> getAdminStats() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/stats/admin/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<Map<String, dynamic>?> getOfficerStats() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/stats/officer/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<Map<String, dynamic>?> getTSPStats() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/stats/tsp/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // Permission settings
  Future<bool> updateAutoApproval(bool isEnabled) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'auto_approval_mode': isEnabled,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['auto_approval_mode'] ?? false;
      }
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<bool> updateAutoRouting(bool isEnabled) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'auto_routing_mode': isEnabled,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['auto_routing_mode'] ?? false;
      }
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<bool> updateAdminAbsentMode(bool isEnabled) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'admin_absent_mode': isEnabled,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['admin_absent_mode'] ?? false;
      }
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<String> updateAdminAbsentModeType(String type) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'admin_absent_mode_type': type,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['admin_absent_mode_type'] ?? type;
      }
    } catch (e) {
      // Handle
    }
    return type;
  }


  Future<bool> updateAllowDirectForwarding(bool isEnabled) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'allow_direct_forwarding': isEnabled,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['allow_direct_forwarding'] ?? false;
      }
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<String> updateAdminMobileNumber(String number) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'admin_mobile_number': number,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['admin_mobile_number'] ?? number;
      }
    } catch (e) {
      // Handle
    }
    return number;
  }

  Future<String> updateAdminStatus(String status) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/settings/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'admin_status': status,
        }),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['admin_status'] ?? 'online';
      }
    } catch (e) {
      // Handle
    }
    return 'online';
  }

  Future<List<User>> getFieldOfficers() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/officers/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => User.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<User?> createFieldOfficer(String username, String email, String password, String firstName, String lastName) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/officers/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'username': username,
          'email': email,
          'password': password,
          'first_name': firstName,
          'last_name': lastName,
        }),
      );
      if (response.statusCode == 201) {
        final data = jsonDecode(response.body);
        return User.fromJson(data);
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<bool> toggleOfficerPermission(int officerId, bool allowed) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/permissions/toggle-officer/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'officer_id': officerId,
          'allowed': allowed,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<bool> toggleOfficerBypassLimit(int officerId, bool bypassLimit, {int? extraRequestsLimit, int? bypassDays}) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/permissions/toggle-officer/'),
        headers: _getHeaders(),
        body: jsonEncode({
          'officer_id': officerId,
          'bypass_daily_limit': bypassLimit,
          'extra_requests_limit': extraRequestsLimit,
          'bypass_days': bypassDays,
        }),
      );
      return response.statusCode == 200;
    } catch (e) {
      // Handle
    }
    return false;
  }

  // Notifications
  Future<List<Map<String, dynamic>>> getNotifications() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/notifications/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<void> markNotificationsRead() async {
    try {
      await http.post(Uri.parse('$_baseUrl/notifications/mark-all-read/'), headers: _getHeaders());
    } catch (e) {
      // Handle
    }
  }

  // Activity logs
  Future<List<ActivityLog>> getActivityLogs() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/logs/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => ActivityLog.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  // Report URIs
  String getReportDownloadUrl({String? format, String? status, int? tspId, int? officerId}) {
    final List<String> params = ['format=${format ?? 'excel'}'];
    if (status != null && status.isNotEmpty) params.add('status=$status');
    if (tspId != null) params.add('tsp=$tspId');
    if (officerId != null) params.add('officer=$officerId');
    
    return '$_baseUrl/reports/?${params.join('&')}';
  }

  // Chat actions
  Future<List<ChatMessage>> getChatMessages({int? requestId}) async {
    try {
      String query = '';
      if (requestId != null) {
        query = '?request_id=$requestId';
      }
      final response = await http.get(Uri.parse('$_baseUrl/chats/$query'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => ChatMessage.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<ChatMessage?> sendChatMessage(String message, {int? requestId, int? receiverId}) async {
    try {
      final Map<String, dynamic> body = {
        'message': message,
      };
      if (requestId != null) body['request'] = requestId;
      if (receiverId != null) body['receiver'] = receiverId;

      final response = await http.post(
        Uri.parse('$_baseUrl/chats/'),
        headers: _getHeaders(),
        body: jsonEncode(body),
      );

      if (response.statusCode == 201) {
        return ChatMessage.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  // Database Browser (Admin)
  Future<Map<String, dynamic>> getDatabaseStructure() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/database-browser/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      // Handle
    }
    return {"requests": [], "chats": []};
  }

  // TSP Responses CRUD & Actions
  Future<List<TSPResponseModel>> getTSPResponses() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/tsp-responses/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => TSPResponseModel.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<TSPResponseModel?> createTSPResponse(Map<String, dynamic> data) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/tsp-responses/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 201) {
        return TSPResponseModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<TSPResponseModel?> updateTSPResponse(int id, Map<String, dynamic> data) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/tsp-responses/$id/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 200) {
        return TSPResponseModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<TSPResponseModel?> sendTSPResponseToOfficer(int id) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/tsp-responses/$id/send-to-officer/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return TSPResponseModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<RequestModel?> closeRequest(int requestId) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/requests/$requestId/close-request/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return RequestModel.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<List<SMSLogModel>> getSMSLogs() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/sms-logs/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => SMSLogModel.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  /// Manually trigger a TextBee SMS poll, bypassing the 10-second server-side cache.
  /// Returns number of new SMS messages processed.
  Future<Map<String, dynamic>?> pollSMS() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/poll-sms/'),
        headers: _getHeaders(),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      // Handle
    }
    return null;
  }
 
  Future<bool> requestLimitBypass() async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/permissions/request-bypass/'),
        headers: _getHeaders(),
      );
      return response.statusCode == 200;
    } catch (e) {
      // Handle
    }
    return false;
  }

  Future<List<TspSetting>> getTspSettings() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/tsp-settings/'), headers: _getHeaders());
      if (response.statusCode == 200) {
        final List data = jsonDecode(response.body);
        return data.map((json) => TspSetting.fromJson(json)).toList();
      }
    } catch (e) {
      // Handle
    }
    return [];
  }

  Future<TspSetting?> createTspSetting(Map<String, dynamic> data) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/tsp-settings/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 201) {
        return TspSetting.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<TspSetting?> updateTspSetting(String id, Map<String, dynamic> data) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/tsp-settings/$id/'),
        headers: _getHeaders(),
        body: jsonEncode(data),
      );
      if (response.statusCode == 200) {
        return TspSetting.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      // Handle
    }
    return null;
  }

  Future<bool> deleteTspSetting(String id) async {
    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/tsp-settings/$id/'),
        headers: _getHeaders(),
      );
      return response.statusCode == 204;
    } catch (e) {
      // Handle
    }
    return false;
  }
}
