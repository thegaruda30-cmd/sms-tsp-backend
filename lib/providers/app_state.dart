import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../models/user.dart';
import '../models/tsp_provider.dart';
import '../models/request.dart';
import '../models/request_status.dart';
import '../models/activity_log.dart';
import '../models/user_role.dart';
import '../models/chat_message.dart';
import '../models/tsp_response.dart';
import '../models/tsp_setting.dart';

class AppState extends ChangeNotifier {
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  bool _isInitialized = false;

  List<RequestModel> _requests = [];
  List<TSPResponseModel> _tspResponses = [];
  List<TSPProvider> _tsps = [
    TSPProvider(id: 1, name: 'Jio', code: 'JIO', contactEmail: 'jio@smstsp.com', mobileNumber: '8310695096', inboundNumber: '9844281875', isDefault: false, isActive: true),
    TSPProvider(id: 5, name: 'Airtel', code: 'AIRTEL', contactEmail: 'airtel@smstsp.com', mobileNumber: '3451', inboundNumber: '9844281875', isDefault: false, isActive: true),
    TSPProvider(id: 6, name: 'BSNL', code: 'BSNL', contactEmail: 'bsnl@smstsp.com', mobileNumber: '9876543213', inboundNumber: '9844281875', isDefault: false, isActive: true),
    TSPProvider(id: 7, name: 'Vi (Vodafone Idea)', code: 'VI', contactEmail: 'vi@smstsp.com', mobileNumber: '9876543212', inboundNumber: '9844281875', isDefault: false, isActive: true),
  ];
  List<ActivityLog> _activityLogs = [];
  List<Map<String, dynamic>> _notifications = [];
  List<User> _fieldOfficers = [];
  List<ChatMessage> _chatMessages = [];
  List<SMSLogModel> _smsLogs = [];
  List<TspSetting> _tspSettings = [];

  Map<String, dynamic> _adminStats = {};
  Map<String, dynamic> _officerStats = {};
  Map<String, dynamic> _tspStats = {};

  bool _adminAbsentMode = false;
  bool _allowDirectForwarding = false;
  String _adminStatus = 'online';
  String _adminMobileNumber = '9844281875';
  bool _isServerConnected = true;

  // Getters
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  User? get currentUser => _apiService.currentUser;
  List<RequestModel> get requests => _requests;
  List<TSPResponseModel> get tspResponses => _tspResponses;
  bool get adminAbsentMode => _adminAbsentMode;
  String get adminAbsentModeType => _adminStats['admin_absent_mode_type'] ?? 'all';
  /// For officers: reflects the per-officer permission granted by admin (directForwardAllowed).
  /// For admins: reflects the global allow_direct_forwarding system setting.
  bool get allowDirectForwarding {
    final user = currentUser;
    if (user != null && user.role == UserRole.OFFICER) {
      return user.directForwardAllowed;
    }
    return _allowDirectForwarding;
  }

  /// True when admin has enabled direct Admin↔TSP messaging (works for all roles).
  bool get allowDirectMessaging {
    final user = currentUser;
    if (user != null && user.role == UserRole.TSP) {
      return _tspStats['allow_direct_messaging'] ?? false;
    }
    return _allowDirectForwarding;
  }

  /// The admin's user ID (needed by TSP to address messages to admin).
  int? get adminUserId => _tspStats['admin_user_id'] as int?;
  String get adminStatus => _adminStatus;
  String get adminMobileNumber => _adminMobileNumber;
  List<TSPProvider> get tsps => _tsps;
  List<ActivityLog> get activityLogs => _activityLogs;
  List<Map<String, dynamic>> get notifications => _notifications;
  int get unreadNotificationsCount => _notifications.where((n) => n['is_read'] == false).length;
  List<User> get fieldOfficers => _fieldOfficers;
  List<ChatMessage> get chatMessages => _chatMessages;
  List<SMSLogModel> get smsLogs => _smsLogs;
  List<TspSetting> get tspSettings => _tspSettings;
  bool get isServerConnected => _isServerConnected;

  Map<String, dynamic> get adminStats => _adminStats;
  Map<String, dynamic> get officerStats => _officerStats;
  Map<String, dynamic> get tspStats => _tspStats;

  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    await _apiService.init();
    _isInitialized = true;

    if (currentUser != null) {
      await loadDashboardData();
    }

    _isLoading = false;
    notifyListeners();
  }

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    notifyListeners();

    try {
      final success = await _apiService.login(username, password);
      if (success) {
        // Trigger dashboard load in the background, do NOT await it here.
        // This allows the login process to complete and redirect to dashboard instantly.
        loadDashboardData();
      }
      _isLoading = false;
      notifyListeners();
      return success;
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      rethrow; // Let the UI handle and display the real error
    }
  }

  Future<void> logout() async {
    _isLoading = true;
    notifyListeners();

    await _apiService.logout();
    _requests = [];
    _tsps = [];
    _activityLogs = [];
    _notifications = [];
    _fieldOfficers = [];
    _tspSettings = [];
    _adminStats = {};
    _officerStats = {};
    _tspStats = {};

    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadDashboardData() async {
    // Populate default local TSPs
    _tsps = [
      TSPProvider(id: 1, name: 'Jio', code: 'JIO', contactEmail: 'jio@smstsp.com', mobileNumber: '8310695096', inboundNumber: '9844281875', isDefault: false, isActive: true),
      TSPProvider(id: 5, name: 'Airtel', code: 'AIRTEL', contactEmail: 'airtel@smstsp.com', mobileNumber: '3451', inboundNumber: '9844281875', isDefault: false, isActive: true),
      TSPProvider(id: 6, name: 'BSNL', code: 'BSNL', contactEmail: 'bsnl@smstsp.com', mobileNumber: '9876543213', inboundNumber: '9844281875', isDefault: false, isActive: true),
      TSPProvider(id: 7, name: 'Vi (Vodafone Idea)', code: 'VI', contactEmail: 'vi@smstsp.com', mobileNumber: '9876543212', inboundNumber: '9844281875', isDefault: false, isActive: true),
    ];

    if (currentUser == null) return;

    try {
      final List<Future<dynamic>> futures = [
        _apiService.getProfile(),
        _apiService.getTSPs(),
        _apiService.getRequests(),
        _apiService.getNotifications(),
      ];

      int? adminStatsIdx, fieldOfficersIdx, activityLogsIdx, tspResponsesIdx, smsLogsIdx, tspSettingsIdx;
      int? officerStatsIdx;
      int? tspStatsIdx;

      if (currentUser!.role == UserRole.ADMIN) {
        adminStatsIdx = futures.length;
        futures.add(_apiService.getAdminStats());
        
        fieldOfficersIdx = futures.length;
        futures.add(_apiService.getFieldOfficers());
        
        activityLogsIdx = futures.length;
        futures.add(_apiService.getActivityLogs());
        
        tspResponsesIdx = futures.length;
        futures.add(_apiService.getTSPResponses());
        
        smsLogsIdx = futures.length;
        futures.add(_apiService.getSMSLogs());
        
        tspSettingsIdx = futures.length;
        futures.add(_apiService.getTspSettings());
      } else if (currentUser!.role == UserRole.OFFICER) {
        officerStatsIdx = futures.length;
        futures.add(_apiService.getOfficerStats());
      } else if (currentUser!.role == UserRole.TSP) {
        tspStatsIdx = futures.length;
        futures.add(_apiService.getTSPStats());
      }

      // Run ALL requests concurrently
      final results = await Future.wait(futures).timeout(const Duration(seconds: 30));
      _isServerConnected = true;

      final fetchedTsps = results[1] as List<TSPProvider>;
      if (fetchedTsps.isNotEmpty) {
        _tsps = fetchedTsps;
      }
      _requests = results[2] as List<RequestModel>;
      _notifications = (results[3] as List).cast<Map<String, dynamic>>();

      if (currentUser!.role == UserRole.ADMIN) {
        final stats = results[adminStatsIdx!] as Map<String, dynamic>?;
        if (stats != null) {
          _adminStats = stats;
          _adminAbsentMode = stats['admin_absent_mode'] ?? false;
          _allowDirectForwarding = stats['allow_direct_forwarding'] ?? false;
          _adminStatus = stats['admin_status'] ?? 'online';
          _adminMobileNumber = stats['admin_mobile_number'] ?? '9844281875';
        }
        _fieldOfficers = results[fieldOfficersIdx!] as List<User>;
        _activityLogs = results[activityLogsIdx!] as List<ActivityLog>;
        _tspResponses = results[tspResponsesIdx!] as List<TSPResponseModel>;
        _smsLogs = results[smsLogsIdx!] as List<SMSLogModel>;
        _tspSettings = results[tspSettingsIdx!] as List<TspSetting>;
      } else if (currentUser!.role == UserRole.OFFICER) {
        final stats = results[officerStatsIdx!] as Map<String, dynamic>?;
        if (stats != null) _officerStats = stats;
      } else if (currentUser!.role == UserRole.TSP) {
        final stats = results[tspStatsIdx!] as Map<String, dynamic>?;
        if (stats != null) {
          _tspStats = stats;
          // Also sync the direct forwarding flag so allowDirectForwarding works for TSP role too
          _allowDirectForwarding = stats['allow_direct_messaging'] ?? false;
        }
      }
    } catch (e) {
      _isServerConnected = false;
      // Log error and fallback silently
      // ignore: avoid_print
      print('[DASHBOARD DATA TIMEOUT/ERROR] $e');
    }
    notifyListeners();
  }

  Future<bool> createRequest(String mobileNumber, int tspId, {required String remarks, String stationName = '', String crNo = '', String subject = '', String message = ''}) async {
    _isLoading = true;
    notifyListeners();

    // Create a local/mock request object and save in code
    final selectedTsp = _tsps.firstWhere((t) => t.id == tspId, orElse: () => _tsps.first);
    
    final shouldAutoForward = currentUser?.directForwardAllowed ?? false;
    final reqStatus = shouldAutoForward ? RequestStatus.FORWARDED : RequestStatus.PENDING;
    final adminStatusText = shouldAutoForward ? 'Forwarded to TSP' : 'Pending';

    final mockRequest = RequestModel(
      crNo: crNo,
      location: '',
      stationName: stationName,
      id: _requests.length + 1,
      mobileNumber: mobileNumber,
      tspId: tspId,
      tspDetails: selectedTsp,
      reason: '',
      status: reqStatus,
      officerId: currentUser?.id ?? 2,
      officerDetails: currentUser,
      officerName: currentUser != null ? '${currentUser!.firstName} ${currentUser!.lastName}'.trim() : 'Officer',
      remarks: remarks,
      adminRemarks: '',
      isAutoApproved: shouldAutoForward,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      forwardedAt: shouldAutoForward ? DateTime.now() : null,
      response: '',
      adminStatus: adminStatusText,
      statusLogs: [
        StatusLog(
          id: 1,
          status: reqStatus.toShortString(),
          changedByName: currentUser != null ? '${currentUser!.firstName} ${currentUser!.lastName}'.trim() : 'Officer',
          changedByRole: 'Officer',
          remarks: shouldAutoForward ? 'Request auto-routed to TSP queue.' : 'Request submitted.',
          timestamp: DateTime.now(),
        ),
      ],
      subject: subject,
      message: message,
      ticketId: 'TSPTKT-${_requests.length + 1}',
      smsLogs: [],
    );
    
    _requests.insert(0, mockRequest);

    // Also attempt API request in background (silent fallthrough)
    try {
      final req = await _apiService.createRequest(mobileNumber, tspId, remarks: remarks, stationName: stationName, crNo: crNo, subject: subject, message: message);
      if (req != null) {
        final index = _requests.indexWhere((r) => r.mobileNumber == mobileNumber && r.remarks == remarks);
        if (index != -1) {
          _requests[index] = req;
        }
      }
    } catch (e) {
      // Offline fallback
    }

    _isLoading = false;
    notifyListeners();
    return true;
  }

  Future<bool> forwardToTsp(int requestId) async {
    _isLoading = true;
    notifyListeners();

    final req = await _apiService.forwardToTsp(requestId);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> tspAccept(int requestId) async {
    _isLoading = true;
    notifyListeners();

    final req = await _apiService.tspAccept(requestId);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> tspReject(int requestId) async {
    _isLoading = true;
    notifyListeners();

    final req = await _apiService.tspReject(requestId);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> tspRespond(int requestId, String details, {String notes = ''}) async {
    _isLoading = true;
    notifyListeners();

    final req = await _apiService.tspRespond(requestId, details, notes: notes);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  // Chats State Management
  Future<void> loadChatMessages(int requestId) async {
    _chatMessages = [];
    notifyListeners();
    try {
      final messages = await _apiService.getChatMessages(requestId: requestId);
      _chatMessages = messages;
    } catch (e) {
      // Handle
    }
    
    // Offline / dummy backup: if there are no messages, create a mock request message representing the request
    if (_chatMessages.isEmpty && _requests.isNotEmpty) {
      final req = _requests.firstWhere((r) => r.id == requestId, orElse: () => _requests.first);
      final mockMsg = ChatMessage(
        id: 1,
        sender: req.officerId,
        senderName: req.officerDetails?.username ?? 'officer',
        senderRole: 'OFFICER',
        receiver: 1,
        receiverName: 'admin',
        receiverRole: 'ADMIN',
        requestId: requestId,
        message: "🚨 **New Lookup Request** 🚨\n\n"
                 "📱 **Number:** ${req.mobileNumber}\n"
                 "📶 **TSP:** ${req.tspDetails?.name ?? 'Jio'}\n"
                 "💬 **Remarks:** ${req.remarks.isEmpty ? 'N/A' : req.remarks}",
        timestamp: req.createdAt,
      );
      _chatMessages.add(mockMsg);
    }
    notifyListeners();
  }

  Future<bool> sendChatMessage(String message, int requestId, {int? receiverId}) async {
    final msg = await _apiService.sendChatMessage(message, requestId: requestId, receiverId: receiverId);
    if (msg != null) {
      _chatMessages.add(msg);
      notifyListeners();
      return true;
    } else {
      // Offline fallback: append a mock message locally
      final mockMsg = ChatMessage(
        id: _chatMessages.length + 1,
        sender: currentUser?.id ?? 2, // Default to officer
        senderName: currentUser?.username ?? 'officer_ranjeet',
        senderRole: currentUser?.role.toShortString() ?? 'OFFICER',
        receiver: receiverId ?? 1,
        receiverName: 'admin',
        receiverRole: 'ADMIN',
        requestId: requestId,
        message: message,
        timestamp: DateTime.now(),
      );
      _chatMessages.add(mockMsg);
      notifyListeners();
      return true;
    }
  }

  Future<Map<String, dynamic>> getDatabaseStructure() async {
    return await _apiService.getDatabaseStructure();
  }

  Future<bool> adminReview(int requestId, String action, String remarks) async {
    _isLoading = true;
    notifyListeners();

    final request = await _apiService.adminReview(requestId, action, remarks);
    if (request != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = request;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> adminComplete(int requestId, String remarks) async {
    _isLoading = true;
    notifyListeners();

    final request = await _apiService.adminComplete(requestId, remarks);
    if (request != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = request;
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }

    _isLoading = false;
    notifyListeners();
    return false;
  }



  Future<void> toggleAutoApproval(bool isEnabled) async {
    try {
      final result = await _apiService.updateAutoApproval(isEnabled);
      _adminStats['auto_approval_mode'] = result;
    } catch (e) {
      _adminStats['auto_approval_mode'] = isEnabled;
    }
    notifyListeners();
  }

  Future<void> toggleAutoRouting(bool isEnabled) async {
    try {
      final result = await _apiService.updateAutoRouting(isEnabled);
      _adminStats['auto_routing_mode'] = result;
    } catch (e) {
      _adminStats['auto_routing_mode'] = isEnabled;
    }
    notifyListeners();
  }

  Future<void> toggleOfficerPermission(int officerId, bool allowed) async {
    // Optimistically update local state so the switch responds immediately
    final idx = _fieldOfficers.indexWhere((o) => o.id == officerId);
    if (idx != -1) {
      final o = _fieldOfficers[idx];
      _fieldOfficers[idx] = User(
        id: o.id, username: o.username, email: o.email, role: o.role,
        directForwardAllowed: allowed,
        bypassDailyLimit: o.bypassDailyLimit,
        bypassRequested: o.bypassRequested,
        extraRequestsLimit: o.extraRequestsLimit,
        bypassExpiryDate: o.bypassExpiryDate,
        isBypassActive: o.isBypassActive,
        firstName: o.firstName, lastName: o.lastName,
        tspProviderId: o.tspProviderId,
      );
      notifyListeners();
    }
    // Fire API call in background, refresh silently
    _apiService.toggleOfficerPermission(officerId, allowed).then((success) {
      if (success) loadDashboardData();
    });
  }

  Future<void> toggleOfficerBypassLimit(int officerId, bool bypassLimit, {int? extraRequestsLimit, int? bypassDays}) async {
    // Optimistically update local state so the switch responds immediately
    final idx = _fieldOfficers.indexWhere((o) => o.id == officerId);
    if (idx != -1) {
      final o = _fieldOfficers[idx];
      _fieldOfficers[idx] = User(
        id: o.id, username: o.username, email: o.email, role: o.role,
        directForwardAllowed: o.directForwardAllowed,
        bypassDailyLimit: bypassLimit,
        bypassRequested: bypassLimit ? false : o.bypassRequested,
        extraRequestsLimit: extraRequestsLimit ?? o.extraRequestsLimit,
        bypassExpiryDate: o.bypassExpiryDate,
        isBypassActive: bypassLimit,
        firstName: o.firstName, lastName: o.lastName,
        tspProviderId: o.tspProviderId,
      );
      notifyListeners();
    }
    // Fire API call in background, refresh silently
    _apiService.toggleOfficerBypassLimit(officerId, bypassLimit, extraRequestsLimit: extraRequestsLimit, bypassDays: bypassDays).then((success) {
      if (success) loadDashboardData();
    });
  }

  Future<bool> requestLimitBypass() async {
    _isLoading = true;
    notifyListeners();
    final success = await _apiService.requestLimitBypass();
    if (success) {
      await loadDashboardData();
    }
    _isLoading = false;
    notifyListeners();
    return success;
  }

  Future<bool> createFieldOfficer({
    required String username,
    required String email,
    required String password,
    String firstName = '',
    String lastName = '',
  }) async {
    _isLoading = true;
    notifyListeners();
    final officer = await _apiService.createFieldOfficer(username, email, password, firstName, lastName);
    if (officer != null) {
      _fieldOfficers.insert(0, officer);
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> markNotificationsRead() async {
    await _apiService.markNotificationsRead();
    await loadDashboardData();
  }

  Future<bool> createTSPResponse(Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final resp = await _apiService.createTSPResponse(data);
    if (resp != null) {
      _tspResponses.insert(0, resp);
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> updateTSPResponse(int id, Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final resp = await _apiService.updateTSPResponse(id, data);
    if (resp != null) {
      final idx = _tspResponses.indexWhere((r) => r.id == id);
      if (idx != -1) {
        _tspResponses[idx] = resp;
      }
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> sendTSPResponseToOfficer(int id) async {
    _isLoading = true;
    notifyListeners();
    final resp = await _apiService.sendTSPResponseToOfficer(id);
    if (resp != null) {
      final idx = _tspResponses.indexWhere((r) => r.id == id);
      if (idx != -1) {
        _tspResponses[idx] = resp;
      }
      if (resp.requestId != null) {
        final reqIdx = _requests.indexWhere((r) => r.id == resp.requestId);
        if (reqIdx != -1) {
          final oldReq = _requests[reqIdx];
          _requests[reqIdx] = RequestModel(
            id: oldReq.id,
            crNo: oldReq.crNo,
            location: oldReq.location,
            stationName: oldReq.stationName,
            mobileNumber: oldReq.mobileNumber,
            tspId: oldReq.tspId,
            tspDetails: oldReq.tspDetails,
            reason: oldReq.reason,
            status: RequestStatus.COMPLETED,
            officerId: oldReq.officerId,
            officerDetails: oldReq.officerDetails,
            officerName: oldReq.officerName,
            remarks: oldReq.remarks,
            adminRemarks: oldReq.adminRemarks,
            isAutoApproved: oldReq.isAutoApproved,
            createdAt: oldReq.createdAt,
            updatedAt: DateTime.now(),
            forwardedAt: oldReq.forwardedAt,
            response: resp.details,
            adminStatus: 'Completed',
            statusLogs: oldReq.statusLogs,
            subject: oldReq.subject,
            message: oldReq.message,
            ticketId: oldReq.ticketId,
            smsLogs: oldReq.smsLogs,
          );
        }
      }
      loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    // Offline / optimistic fallback
    final idx = _tspResponses.indexWhere((r) => r.id == id);
    if (idx != -1) {
      final old = _tspResponses[idx];
      _tspResponses[idx] = TSPResponseModel(
        id: old.id,
        requestId: old.requestId,
        details: old.details,
        submittedBy: old.submittedBy,
        submittedByName: old.submittedByName,
        timestamp: old.timestamp,
        mobileNumber: old.mobileNumber,
        tspProvider: old.tspProvider,
        subscriberStatus: old.subscriberStatus,
        circle: old.circle,
        activationDate: old.activationDate,
        additionalNotes: old.additionalNotes,
        responseDate: DateTime.now(),
        status: 'Sent to Officer',
        createdBy: old.createdBy,
        createdByName: old.createdByName,
        createdAt: old.createdAt,
      );
      
      if (old.requestId != null) {
        final reqIdx = _requests.indexWhere((r) => r.id == old.requestId);
        if (reqIdx != -1) {
          final oldReq = _requests[reqIdx];
          final formattedDetails =
              "Subscriber Status: ${old.subscriberStatus}\nCircle/State: ${old.circle}\nActivation Date: ${old.activationDate != null ? old.activationDate!.toIso8601String().substring(0, 10) : 'N/A'}\nAdditional Notes: ${old.additionalNotes}";
          _requests[reqIdx] = RequestModel(
            id: oldReq.id,
            crNo: oldReq.crNo,
            location: oldReq.location,
            stationName: oldReq.stationName,
            mobileNumber: oldReq.mobileNumber,
            tspId: oldReq.tspId,
            tspDetails: oldReq.tspDetails,
            reason: oldReq.reason,
            status: RequestStatus.COMPLETED,
            officerId: oldReq.officerId,
            officerDetails: oldReq.officerDetails,
            officerName: oldReq.officerName,
            remarks: oldReq.remarks,
            adminRemarks: oldReq.adminRemarks,
            isAutoApproved: oldReq.isAutoApproved,
            createdAt: oldReq.createdAt,
            updatedAt: DateTime.now(),
            forwardedAt: oldReq.forwardedAt,
            response: old.details.isNotEmpty ? old.details : formattedDetails,
            adminStatus: 'Completed',
            statusLogs: oldReq.statusLogs,
            subject: oldReq.subject,
            message: oldReq.message,
            ticketId: oldReq.ticketId,
            smsLogs: oldReq.smsLogs,
          );
        }
      }
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<void> toggleAdminAbsentMode(bool isEnabled) async {
    try {
      final result = await _apiService.updateAdminAbsentMode(isEnabled);
      _adminAbsentMode = result;
      _adminStats['admin_absent_mode'] = result;
    } catch (e) {
      _adminAbsentMode = isEnabled;
    }
    notifyListeners();
  }

  Future<void> updateAdminAbsentModeType(String type) async {
    try {
      final result = await _apiService.updateAdminAbsentModeType(type);
      _adminStats['admin_absent_mode_type'] = result;
    } catch (e) {
      _adminStats['admin_absent_mode_type'] = type;
    }
    notifyListeners();
  }


  Future<void> toggleAllowDirectForwarding(bool isEnabled) async {
    try {
      final result = await _apiService.updateAllowDirectForwarding(isEnabled);
      _allowDirectForwarding = result;
      _adminStats['allow_direct_forwarding'] = result;
    } catch (e) {
      _allowDirectForwarding = isEnabled;
    }
    notifyListeners();
  }

  Future<void> updateAdminStatus(String status) async {
    try {
      final result = await _apiService.updateAdminStatus(status);
      _adminStatus = result;
      _adminStats['admin_status'] = result;
    } catch (e) {
      _adminStatus = status;
    }
    notifyListeners();
  }

  Future<void> updateAdminMobileNumber(String number) async {
    try {
      final result = await _apiService.updateAdminMobileNumber(number);
      _adminMobileNumber = result;
      _adminStats['admin_mobile_number'] = result;
    } catch (e) {
      _adminMobileNumber = number;
    }
    notifyListeners();
  }

  Future<bool> createTSP(Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final tsp = await _apiService.createTSP(data);
    if (tsp != null) {
      _tsps.add(tsp);
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> updateTSP(int id, Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final tsp = await _apiService.updateTSP(id, data);
    if (tsp != null) {
      final index = _tsps.indexWhere((t) => t.id == id);
      if (index != -1) {
        _tsps[index] = tsp;
      }
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> deleteTSP(int id) async {
    _isLoading = true;
    notifyListeners();
    final success = await _apiService.deleteTSP(id);
    if (success) {
      _tsps.removeWhere((t) => t.id == id);
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> setDefaultTSP(int id) async {
    _isLoading = true;
    notifyListeners();
    final tsp = await _apiService.setDefaultTSP(id);
    if (tsp != null) {
      for (int i = 0; i < _tsps.length; i++) {
        _tsps[i] = TSPProvider(
          id: _tsps[i].id,
          name: _tsps[i].name,
          code: _tsps[i].code,
          contactEmail: _tsps[i].contactEmail,
          mobileNumber: _tsps[i].mobileNumber,
          inboundNumber: _tsps[i].inboundNumber,
          isDefault: _tsps[i].id == id,
          isActive: _tsps[i].isActive,
        );
      }
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> closeRequest(int requestId) async {
    _isLoading = true;
    notifyListeners();
    final req = await _apiService.closeRequest(requestId);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  String getReportDownloadUrl({String? format, String? status, int? tspId, int? officerId}) {
    return _apiService.getReportDownloadUrl(
      format: format,
      status: status,
      tspId: tspId,
      officerId: officerId,
    );
  }

  // Reload action for pull-to-refresh
  Future<void> refresh() async {
    _isLoading = true;
    notifyListeners();
    await loadDashboardData();
    _isLoading = false;
    notifyListeners();
  }

  /// Lightweight refresh: fetch ONLY TSP responses + requests without full dashboard reload.
  /// Called by the admin auto-refresh timer every 10 seconds.
  Future<void> refreshTSPResponses() async {
    if (currentUser == null || currentUser!.role != UserRole.ADMIN) return;
    try {
      final fresh = await _apiService.getTSPResponses();
      bool isChanged = fresh.length != _tspResponses.length;
      if (!isChanged) {
        for (int i = 0; i < fresh.length; i++) {
          final f = fresh[i];
          final o = _tspResponses[i];
          if (f.id != o.id ||
              f.status != o.status ||
              f.subscriberStatus != o.subscriberStatus ||
              f.circle != o.circle ||
              f.details != o.details ||
              f.additionalNotes != o.additionalNotes ||
              f.activationDate != o.activationDate) {
            isChanged = true;
            break;
          }
        }
      }
      if (isChanged) {
        _tspResponses = fresh;
        // Also refresh requests so status shows correctly
        _requests = await _apiService.getRequests();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Force-trigger TextBee SMS polling (bypasses server 10-second cache).
  /// Returns a message string describing how many new SMS were processed.
  Future<String> pollSMS() async {
    try {
      final result = await _apiService.pollSMS();
      // After polling, reload dashboard data to get fresh TSP responses
      await loadDashboardData();
      if (result != null) {
        return result['detail'] ?? 'Poll complete.';
      }
    } catch (e) {
      // Handle
    }
    return 'Poll triggered. Refreshing data...';
  }

  /// Log an inbound TSP SMS response - when TSP sends an SMS to the configured inbound number
  Future<bool> tspSmsResponse(int requestId, String fromNumber, String inboundNumber, String smsBody) async {
    _isLoading = true;
    notifyListeners();
    final req = await _apiService.tspSmsResponse(requestId, fromNumber, inboundNumber, smsBody);
    if (req != null) {
      final index = _requests.indexWhere((r) => r.id == requestId);
      if (index != -1) {
        _requests[index] = req;
      }
      _smsLogs = await _apiService.getSMSLogs();
      _tspResponses = await _apiService.getTSPResponses();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    // Offline fallback: update local state optimistically
    final index = _requests.indexWhere((r) => r.id == requestId);
    if (index != -1) {
      final old = _requests[index];
      _requests[index] = RequestModel(
        id: old.id, crNo: old.crNo, location: old.location, stationName: old.stationName,
        mobileNumber: old.mobileNumber, tspId: old.tspId, tspDetails: old.tspDetails,
        reason: old.reason, status: RequestStatus.TSP_RESPONDED, officerId: old.officerId,
        officerDetails: old.officerDetails, officerName: old.officerName, remarks: old.remarks,
        adminRemarks: old.adminRemarks, isAutoApproved: old.isAutoApproved,
        createdAt: old.createdAt, updatedAt: DateTime.now(), forwardedAt: old.forwardedAt,
        response: smsBody, adminStatus: 'SMS Response Received', statusLogs: old.statusLogs,
        subject: old.subject, message: old.message, ticketId: old.ticketId, smsLogs: old.smsLogs,
      );
    }
    _isLoading = false;
    notifyListeners();
    return true;
  }

  Future<bool> createTspSetting(Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final setting = await _apiService.createTspSetting(data);
    if (setting != null) {
      _tspSettings.add(setting);
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> updateTspSetting(String id, Map<String, dynamic> data) async {
    _isLoading = true;
    notifyListeners();
    final setting = await _apiService.updateTspSetting(id, data);
    if (setting != null) {
      final index = _tspSettings.indexWhere((s) => s.id == id);
      if (index != -1) {
        _tspSettings[index] = setting;
      }
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }

  Future<bool> deleteTspSetting(String id) async {
    _isLoading = true;
    notifyListeners();
    final success = await _apiService.deleteTspSetting(id);
    if (success) {
      _tspSettings.removeWhere((s) => s.id == id);
      await loadDashboardData();
      _isLoading = false;
      notifyListeners();
      return true;
    }
    _isLoading = false;
    notifyListeners();
    return false;
  }
}
