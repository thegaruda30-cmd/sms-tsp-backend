import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/app_state.dart';
import '../../models/user.dart';
import '../../models/user_role.dart';
import '../../models/request.dart';
import '../../models/request_status.dart';
import '../../models/chat_message.dart';
import '../login_screen.dart';
import 'absent_mode_config_screen.dart';
import '../../models/tsp_response.dart';
import '../../models/tsp_provider.dart';
import '../../models/tsp_setting.dart';
import '../../services/api_service.dart';
import '../../services/download_helper_stub.dart'
    if (dart.library.html) '../../services/download_helper_web.dart'
    if (dart.library.io) '../../services/download_helper_nonweb.dart';
import 'dart:io';
import 'package:excel/excel.dart' as xl;
import 'package:path_provider/path_provider.dart';

class _PageBox {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final int panel;

  const _PageBox({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.panel,
  });
}

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  int? _currentPanel; // null = home grid, otherwise panel index
  int _settingsTabIndex = 0; // 0: General, 1: TSP Config, 2: SMS Logs
  User? _selectedChatOfficer;
  RequestModel? _activeChatRequest;
  
  // TSP search and filter states
  String _tspSearchQuery = "";
  String _tspStatusFilter = "All";

  // All Requests filter state
  String _allRequestsTspFilter = "All";

  // TSP Selection Hub new states
  TSPProvider? _selectedTspForSelection;
  final _tspNumberController = TextEditingController();

  // TSP Responses states
  String _responsesTspFilter = "All";
  String _responsesStatusFilter = "All";
  String _responsesSearchQuery = "";

  // Reports states
  String _reportsTspFilter = "All";
  String _reportsOfficerFilter = "All";
  String _reportsStatusFilter = "All";
  DateTime? _reportsDateFilter;
  String _reportsMonthFilter = "All";
  String _reportsWeekFilter = "All";
  String _reportsSortOrder = "Date (Newest)";

  int _getMonthNumber(String monthName) {
    switch (monthName) {
      case "January": return 1;
      case "February": return 2;
      case "March": return 3;
      case "April": return 4;
      case "May": return 5;
      case "June": return 6;
      case "July": return 7;
      case "August": return 8;
      case "September": return 9;
      case "October": return 10;
      case "November": return 11;
      case "December": return 12;
      default: return 0;
    }
  }

  final _scrollController = ScrollController();
  final _messageController = TextEditingController();
  bool _isSending = false;

  // Officer registration form controllers
  final _officerEmailController = TextEditingController();
  final _officerUsernameController = TextEditingController();
  final _officerPasswordController = TextEditingController();
  final _officerFirstNameController = TextEditingController();
  final _officerLastNameController = TextEditingController();
  bool _isRegisteringOfficer = false;
  final _adminMobileNumberController = TextEditingController();
 
  // TSP Settings section controllers
  final Map<String, TextEditingController> _tspForwardNumControllers = {};
  final Map<String, TextEditingController> _tspSmsTemplateControllers = {};


  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {

    _scrollController.dispose();
    _messageController.dispose();
    _officerEmailController.dispose();
    _officerUsernameController.dispose();
    _officerPasswordController.dispose();
    _officerFirstNameController.dispose();
    _officerLastNameController.dispose();
    _tspNumberController.dispose();
    _adminMobileNumberController.dispose();
    for (final controller in _tspForwardNumControllers.values) {
      controller.dispose();
    }
    for (final controller in _tspSmsTemplateControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }



  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent + 100,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _loadRequestChat(RequestModel request) async {
    setState(() {
      _activeChatRequest = request;
      _selectedChatOfficer = request.officerDetails ?? 
        User(
          id: request.officerId, 
          username: "officer_ranjeet", 
          email: "officer@smstsp.com", 
          role: UserRole.OFFICER, 
          directForwardAllowed: true, 
          bypassDailyLimit: false, 
          bypassRequested: false,
          extraRequestsLimit: 0,
          bypassExpiryDate: null,
          isBypassActive: false,
          firstName: "Ranjeet", 
          lastName: "Kumar"
        );
    });
    final state = Provider.of<AppState>(context, listen: false);
    await state.loadChatMessages(request.id);
    _scrollToBottom();
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _activeChatRequest == null) return;

    setState(() {
      _isSending = true;
    });

    final state = Provider.of<AppState>(context, listen: false);

    // When Direct Send is ON, message goes to the TSP user for this request.
    // When OFF, message goes to the officer as usual.
    int? targetReceiverId;
    if (state.allowDirectMessaging) {
      // Find the TSP user whose tsp_provider matches this request's tspId
      final tspUser = state.fieldOfficers.where((u) =>
        u.role == UserRole.TSP && u.tspProviderId == _activeChatRequest!.tspId
      ).firstOrNull;
      targetReceiverId = tspUser?.id;
    } else {
      targetReceiverId = _activeChatRequest!.officerId;
    }

    final success = await state.sendChatMessage(
      text,
      _activeChatRequest!.id,
      receiverId: targetReceiverId,
    );

    if (success) {
      _messageController.clear();
      _scrollToBottom();
    }

    setState(() {
      _isSending = false;
    });
  }

  void _reviewRequest(AppState state, RequestModel req, String action, String remarks) async {
    final success = await state.adminReview(req.id, action, remarks);
    if (success) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Request ${action == 'APPROVE' ? 'approved & forwarded to TSP' : 'rejected'} successfully!")),
      );
      // Reload chat to show automated notification message
      state.loadChatMessages(req.id);
      setState(() {
        // Refresh active chat request object with new status
        final updated = state.requests.where((r) => r.id == req.id);
        if (updated.isNotEmpty) _activeChatRequest = updated.first;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final user = state.currentUser;

    if (user == null) {
      return const LoginScreen();
    }

    final bool showingPanel = _currentPanel != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: showingPanel
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
                onPressed: () {
                  setState(() {
                    if (_currentPanel != null && _currentPanel! >= 1 && _currentPanel! <= 4) {
                      _currentPanel = 10;
                    } else {
                      _currentPanel = null;
                    }
                  });
                },
              )
            : null,
        titleSpacing: showingPanel ? 0 : 16,
        title: showingPanel
            ? Text(
                _getPanelTitle(_currentPanel!),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17),
              )
            : Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF4F46E5)]),
                      boxShadow: [BoxShadow(color: const Color(0xFF6366F1).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))],
                    ),
                    child: const Icon(Icons.shield_outlined, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Admin Dashboard', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15), overflow: TextOverflow.ellipsis),
                        Text('SMS TSP SYSTEM', style: TextStyle(color: Colors.grey, fontSize: 9, letterSpacing: 0.5), overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.grey, size: 20),
            onPressed: () => state.refresh(),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.grey, size: 20),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  backgroundColor: const Color(0xFF1E293B),
                  title: const Text("Log Out", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  content: const Text("Are you sure you want to log out?", style: TextStyle(color: Colors.grey, fontSize: 13)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text("Log Out", style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
              if (confirm == true) {
                await state.logout();
                if (!mounted) return;
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                );
              }
            },
            tooltip: 'Log Out',
          ),
          if (!showingPanel)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF6366F1).withOpacity(0.5), width: 2),
              ),
              child: CircleAvatar(
                radius: 15,
                backgroundColor: const Color(0xFF6366F1).withOpacity(0.15),
                child: Text(
                  user.fullName.isNotEmpty ? user.fullName[0].toUpperCase() : 'A',
                  style: const TextStyle(color: Color(0xFF6366F1), fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // Server disconnected banner
          if (!state.isServerConnected)
            Material(
              color: Colors.transparent,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.red.shade900.withOpacity(0.85),
                  border: Border(bottom: BorderSide(color: Colors.red.shade700.withOpacity(0.4))),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_rounded, color: Colors.redAccent, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Server connection lost. Data may be stale.',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => state.refresh(),
                      icon: const Icon(Icons.refresh_rounded, size: 14, color: Colors.white),
                      label: const Text('Retry', style: TextStyle(color: Colors.white, fontSize: 12)),
                      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: showingPanel
                ? _buildPanelContent(state, _currentPanel!)
                : _buildHomeGrid(state, user),
          ),
        ],
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06), width: 1)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, -4)),
          ],
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildBottomNavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  isActive: _currentPanel == null,
                  onTap: () => setState(() => _currentPanel = null),
                ),
                _buildBottomNavItem(
                  icon: Icons.settings_rounded,
                  label: 'Settings',
                  isActive: _currentPanel == 11,
                  onTap: () => setState(() => _currentPanel = 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─── Home Grid ─────────────────────────────────────────────────────────────
  Widget _buildHomeGrid(AppState state, User user) {
    final pendingCount = state.requests.where((r) => r.status == RequestStatus.PENDING).length;
    final completedCount = state.requests.where((r) => r.status == RequestStatus.COMPLETED).length;
    final requestedBypassCount = state.fieldOfficers.where((o) => o.bypassRequested && !o.bypassDailyLimit).length;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Welcome Hero Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(color: const Color(0xFF4F46E5).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Welcome back,',
                            style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            user.fullName,
                            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Icon(Icons.shield_outlined, color: Colors.white, size: 28),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _buildStatPill('${state.requests.length}', 'Total', Colors.white.withOpacity(0.2)),
                    _buildStatPill('$pendingCount', 'Pending', Colors.amber.withOpacity(0.35)),
                    _buildStatPill('$completedCount', 'Done', Colors.greenAccent.withOpacity(0.25)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Admin Modules Section
          const Text(
            'Admin Modules',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.3),
          ),
          const SizedBox(height: 4),
          const Text(
            'Select a module to manage requests, operators, and permissions.',
            style: TextStyle(color: Colors.grey, fontSize: 11.5),
          ),
          const SizedBox(height: 16),

          GridView.count(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.25,
            children: [
              _buildPageBox(
                title: 'Received Requests',
                subtitle: '$pendingCount pending approval',
                icon: Icons.inbox_outlined,
                color: const Color(0xFF06B6D4),
                onTap: () => setState(() => _currentPanel = 5),
              ),
              _buildPageBox(
                title: 'Set TSP Numbers',
                subtitle: 'Configure operator numbers',
                icon: Icons.cell_tower,
                color: Colors.blueAccent,
                onTap: () => setState(() => _currentPanel = 10),
              ),
              _buildPageBox(
                title: 'Manage Officers',
                subtitle: requestedBypassCount > 0
                    ? '$requestedBypassCount bypass request(s) pending'
                    : '${state.fieldOfficers.length} registered officers',
                icon: Icons.people_outline_rounded,
                color: const Color(0xFF6366F1),
                onTap: () => setState(() => _currentPanel = 7),
                badgeCount: requestedBypassCount,
              ),
              _buildPageBox(
                title: 'TSP Replies',
                subtitle: '${state.tspResponses.length} replies',
                icon: Icons.reply_all_rounded,
                color: Colors.greenAccent,
                onTap: () => setState(() => _currentPanel = 6),
              ),
              _buildPageBox(
                title: 'Reports',
                subtitle: 'Download Excel reports',
                icon: Icons.bar_chart_rounded,
                color: Colors.orangeAccent,
                onTap: () => setState(() => _currentPanel = 12),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Bottom Nav Item ───────────────────────────────────────────────────────
  Widget _buildBottomNavItem({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    final color = isActive ? const Color(0xFF6366F1) : Colors.grey[500]!;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFF6366F1).withOpacity(0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(color: color, fontSize: 10, fontWeight: isActive ? FontWeight.bold : FontWeight.normal),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Settings Panel ────────────────────────────────────────────────────────
  Widget _buildSettingsPanel(AppState state) {
    final absentMode = state.adminAbsentMode;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF334155), Color(0xFF1E293B)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.06)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.settings_rounded, color: Color(0xFF6366F1), size: 26),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('System Settings', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 17)),
                    SizedBox(height: 2),
                    Text('Control system-wide behaviour', style: TextStyle(color: Colors.grey, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),

          // Section: Admin Availability / Absent Mode Settings
          const Text(
            'Admin Availability',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.3),
          ),
          const SizedBox(height: 4),
          Text(
            'Control request and reply routing when Admin is away.',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 14),

          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: absentMode
                    ? Colors.amberAccent.withOpacity(0.35)
                    : Colors.blueAccent.withOpacity(0.25),
                width: 1.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const AbsentModeConfigScreen(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: (absentMode ? Colors.amberAccent : Colors.blueAccent).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          absentMode ? Icons.person_off_rounded : Icons.person_rounded,
                          color: absentMode ? Colors.amberAccent : Colors.blueAccent,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Direct Send: Admin Absent Mode',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              absentMode
                                  ? 'When Admin is marked absent, requests automatically route to TSPs and replies route back to officers.'
                                  : 'Admin review required for routing when offline.',
                              style: TextStyle(
                                color: absentMode ? Colors.amberAccent[100] : Colors.blueAccent[100],
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.grey,
                        size: 24,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: state.allowDirectForwarding
                    ? Colors.tealAccent.withOpacity(0.35)
                    : Colors.blueAccent.withOpacity(0.25),
                width: 1.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: (state.allowDirectForwarding ? Colors.tealAccent : Colors.blueAccent).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.swap_horiz_rounded,
                      color: state.allowDirectForwarding ? Colors.tealAccent : Colors.blueAccent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Direct Send: Admin ↔ TSP',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          state.allowDirectForwarding
                              ? 'Enabled: Requests bypass officers. Chat routes directly between Admin and TSPs.'
                              : 'Disabled: Routing and messaging mediated through officers.',
                          style: TextStyle(
                            color: state.allowDirectForwarding ? Colors.tealAccent[100] : Colors.blueAccent[100],
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: state.allowDirectForwarding,
                    onChanged: (val) async {
                      await state.toggleAllowDirectForwarding(val);
                    },
                    activeColor: Colors.tealAccent,
                    activeTrackColor: Colors.tealAccent.withOpacity(0.3),
                    inactiveThumbColor: Colors.blueAccent,
                    inactiveTrackColor: Colors.blueAccent.withOpacity(0.25),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 28),

          // Section: TSP Configuration
          const Text(
            'TSP Configuration',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14, letterSpacing: 0.3),
          ),
          const SizedBox(height: 4),
          Text(
            'Configure outbound forwarding numbers and SMS templates for each operator.',
            style: TextStyle(color: Colors.grey[400], fontSize: 12),
          ),
          const SizedBox(height: 14),

          if (state.tsps.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Text(
                  "No TSPs configured in the system.",
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                ),
              ),
            )
          else
            ...state.tsps.map((tsp) => _buildTspSettingsCard(tsp, state)),

        ],
      ),
    );
  }

  Widget _buildTspSettingsCard(TSPProvider tsp, AppState state) {
    if (!_tspForwardNumControllers.containsKey(tsp.code)) {
      _tspForwardNumControllers[tsp.code] = TextEditingController(text: tsp.mobileNumber);
    }
    if (!_tspSmsTemplateControllers.containsKey(tsp.code)) {
      _tspSmsTemplateControllers[tsp.code] = TextEditingController(text: tsp.smsTemplate);
    }

    final forwardController = _tspForwardNumControllers[tsp.code]!;
    final templateController = _tspSmsTemplateControllers[tsp.code]!;

    Color operatorColor;
    if (tsp.code.toUpperCase() == 'JIO') {
      operatorColor = const Color(0xFF0F52BA);
    } else if (tsp.code.toUpperCase() == 'AIRTEL') {
      operatorColor = const Color(0xFFE40046);
    } else if (tsp.code.toUpperCase() == 'VI') {
      operatorColor = const Color(0xFFFFB300);
    } else {
      operatorColor = const Color(0xFF005A9C);
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.06)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: operatorColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.cell_tower_rounded, color: operatorColor, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  tsp.name,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14.5),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: (tsp.isActive ? Colors.blue : Colors.red).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    tsp.isActive ? "ACTIVE" : "INACTIVE",
                    style: TextStyle(
                      color: tsp.isActive ? Colors.blueAccent : Colors.redAccent,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Forward Number",
                  style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: forwardController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    hintText: "Enter forward number",
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  "SMS Template",
                  style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                TextFormField(
                  controller: templateController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  minLines: 3,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  decoration: InputDecoration(
                    hintText: "e.g., Please provide current location for <Number>",
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                    helperText: "Use placeholder <Number> (e.g. Please provide location for <Number>)",
                    helperStyle: TextStyle(color: Colors.grey, fontSize: 10),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final forwardNum = forwardController.text.trim();
                  final template = templateController.text.trim();

                  if (forwardNum.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Forward number for ${tsp.name} is required"),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                    return;
                  }

                  if (template.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("SMS template for ${tsp.name} is required"),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                    return;
                  }

                  if (!template.toLowerCase().contains('<number>')) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("SMS template for ${tsp.name} must contain the '<Number>' placeholder"),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                    return;
                  }

                  final data = {
                    'name': tsp.name,
                    'code': tsp.code,
                    'contact_email': tsp.contactEmail,
                    'mobile_number': forwardNum,
                    'inbound_number': tsp.inboundNumber,
                    'sms_template': template,
                    'is_active': tsp.isActive,
                  };

                  final success = await state.updateTSP(tsp.id, data);
                  if (success) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("TSP ${tsp.name} settings saved successfully!"),
                        backgroundColor: Colors.green,
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text("Failed to save TSP ${tsp.name} settings"),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.save_rounded, size: 14),
                label: const Text("Save Settings", style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildStatPill(String value, String label, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildPageBox({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    int badgeCount = 0,
  }) {
    return Material(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        splashColor: color.withOpacity(0.08),
        highlightColor: color.withOpacity(0.04),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: color.withOpacity(0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  if (badgeCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEF4444),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: Colors.grey[500], fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getPanelTitle(int panel) {
    switch (panel) {
      case 0: return 'Officer Chats';
      case 1: return 'Airtel Management';
      case 2: return 'Jio Management';
      case 3: return 'Vodafone Idea';
      case 4: return 'BSNL Management';
      case 5: return 'All Requests';
      case 6: return 'TSP Responses';
      case 7: return 'Field Officer Management';
      case 10: return 'TSP Management';
      case 11: return 'Settings';
      case 12: return 'Reports';
      default: return 'Dashboard';
    }
  }

  Widget _buildPanelContent(AppState state, int panel) {
    int getTspIdByCode(String code) {
      final match = state.tsps.where((t) => t.code.toUpperCase() == code.toUpperCase());
      if (match.isNotEmpty) return match.first.id;
      // Database seeded fallbacks
      if (code == 'JIO') return 1;
      if (code == 'AIRTEL') return 5;
      if (code == 'BSNL') return 6;
      if (code == 'VI') return 7;
      return 0;
    }

    switch (panel) {
      case 0: return _buildChatsPanel(state);
      case 1: return _buildTspManagementPage(state, getTspIdByCode('AIRTEL'), 'Bharti Airtel');
      case 2: return _buildTspManagementPage(state, getTspIdByCode('JIO'), 'Reliance Jio');
      case 3: return _buildTspManagementPage(state, getTspIdByCode('VI'), 'Vodafone Idea (Vi)');
      case 4: return _buildTspManagementPage(state, getTspIdByCode('BSNL'), 'BSNL');
      case 5: return _buildAllRequestsPanel(state);
      case 6: return _buildTspResponsesPanel(state);
      case 7: return _buildFieldOfficerManagementPanel(state);
      case 10: return _buildTspSelectionPanel(state);
      case 11: return _buildSettingsPanel(state);
      case 12: return _buildReportsPanel(state);
      default: return const Center(child: Text('Select a panel'));
    }
  }

  Widget _buildTspSelectionPanel(AppState state) {
    // Keep selected provider reference updated in case state was reloaded
    if (_selectedTspForSelection != null) {
      final updated = state.tsps.where((t) => t.id == _selectedTspForSelection!.id);
      if (updated.isNotEmpty) {
        _selectedTspForSelection = updated.first;
      }
    }

    Color getTspColor(String code) {
      switch (code.toUpperCase()) {
        case 'AIRTEL':
          return Colors.redAccent;
        case 'JIO':
          return Colors.blueAccent;
        case 'VI':
          return Colors.purpleAccent;
        case 'BSNL':
          return Colors.orangeAccent;
        default:
          return Colors.indigoAccent;
      }
    }

    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "TSP Management Hub",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
          ),
          const SizedBox(height: 4),
          const Text(
            "Select a Telecom Service Provider to manage requests, review stats, and configure settings.",
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 24),

          // Dropdown Container
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButtonFormField<TSPProvider>(
                value: state.tsps.any((t) => t.id == _selectedTspForSelection?.id)
                    ? state.tsps.firstWhere((t) => t.id == _selectedTspForSelection!.id)
                    : null,
                dropdownColor: const Color(0xFF1E293B),
                hint: const Text("Select a Telecom Provider...", style: TextStyle(color: Colors.grey, fontSize: 14)),
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                decoration: const InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                items: state.tsps.map((tsp) {
                  return DropdownMenuItem<TSPProvider>(
                    value: tsp,
                    child: Row(
                      children: [
                        Icon(Icons.cell_tower, color: getTspColor(tsp.code), size: 20),
                        const SizedBox(width: 12),
                        Text(tsp.name),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (val) {
                  setState(() {
                    _selectedTspForSelection = val;
                    if (val != null) {
                      _tspNumberController.text = val.mobileNumber;
                    }
                  });
                },
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Details Card displayed if a TSP is selected
          Expanded(
            child: _selectedTspForSelection == null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.cell_tower_rounded, size: 64, color: Colors.grey.withOpacity(0.3)),
                        const SizedBox(height: 16),
                        const Text(
                          "No Provider Selected",
                          style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          "Select a provider from the dropdown to configure settings.",
                          style: TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: getTspColor(_selectedTspForSelection!.code).withOpacity(0.15)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: getTspColor(_selectedTspForSelection!.code).withOpacity(0.15),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        Icons.cell_tower,
                                        color: getTspColor(_selectedTspForSelection!.code),
                                        size: 24,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _selectedTspForSelection!.name,
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            "Code: ${_selectedTspForSelection!.code}",
                                            style: TextStyle(color: Colors.grey[400], fontSize: 11),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton.icon(
                                onPressed: () {
                                  // Panel routing mapping based on code:
                                  // Airtel: 1, Jio: 2, Vi: 3, BSNL: 4.
                                  final code = _selectedTspForSelection!.code.toUpperCase();
                                  final p = code == 'AIRTEL'
                                      ? 1
                                      : (code == 'JIO'
                                          ? 2
                                          : (code == 'BSNL'
                                              ? 4
                                              : 3));
                                  setState(() {
                                    _currentPanel = p;
                                  });
                                },
                                icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                                label: const Text("Portal", style: TextStyle(fontSize: 12)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: getTspColor(_selectedTspForSelection!.code).withOpacity(0.2),
                                  foregroundColor: getTspColor(_selectedTspForSelection!.code),
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ],
                          ),
                          const Divider(height: 32, color: Colors.white10),
                          
                          const Text(
                            "Add / Configure TSP Number",
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            "Set the primary outbound gateway mobile number for forwarding requests to this provider.",
                            style: TextStyle(color: Colors.grey, fontSize: 11.5),
                          ),
                          const SizedBox(height: 16),

                          TextFormField(
                            controller: _tspNumberController,
                            style: const TextStyle(color: Colors.white, fontSize: 13.5),
                            decoration: InputDecoration(
                              labelText: "TSP Outbound Number",
                              labelStyle: const TextStyle(color: Colors.grey),
                              hintText: "Enter number (e.g., 3451, 8310695096)",
                              prefixIcon: const Icon(Icons.phone_android_rounded, color: Colors.grey, size: 18),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                              ),
                            ),
                          ),

                          const SizedBox(height: 12),

                          // Warning: do NOT enter the device inbound number as TSP outbound
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.amberAccent.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.amberAccent.withOpacity(0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 16),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Enter the TSP representative\u2019s phone number (NOT the device inbound number 9844281875). Each TSP must have a unique number.',
                                    style: TextStyle(color: Colors.amberAccent.withOpacity(0.85), fontSize: 10.5),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 16),

                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                final newNum = _tspNumberController.text.trim();
                                // Guard: do NOT allow saving the device inbound number as TSP outbound
                                final cleanNum = newNum.replaceAll(RegExp(r'[^0-9]'), '');
                                if (cleanNum.endsWith('9844281875') || cleanNum == '9844281875') {
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text('\u26a0\ufe0f ERROR: This is the device inbound number. You cannot forward requests to it. Enter the actual TSP phone number.'),
                                        backgroundColor: Colors.red,
                                        duration: Duration(seconds: 5),
                                      ),
                                    );
                                  }
                                  return;
                                }
                                final success = await state.updateTSP(_selectedTspForSelection!.id, {
                                  'name': _selectedTspForSelection!.name,
                                  'code': _selectedTspForSelection!.code,
                                  'contact_email': _selectedTspForSelection!.contactEmail,
                                  'mobile_number': newNum,
                                  'inbound_number': _selectedTspForSelection!.inboundNumber,
                                  'is_active': _selectedTspForSelection!.isActive,
                                });
                                if (success && context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("${_selectedTspForSelection!.name} TSP number updated to '$newNum'")),
                                  );
                                  setState(() {
                                    // Update locally saved selected state
                                    final idx = state.tsps.indexWhere((t) => t.id == _selectedTspForSelection!.id);
                                    if (idx != -1) {
                                      _selectedTspForSelection = state.tsps[idx];
                                    }
                                  });
                                }
                              },
                              icon: const Icon(Icons.save_rounded, size: 16),
                              label: const Text("Save TSP Number"),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6366F1),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ─── Menu Panel 1: Chats ───────────────────────────────────────────────────
  Widget _buildChatsPanel(AppState state) {
    final user = state.currentUser;
    final requests = state.requests;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 720;
        
        if (isMobile) {
          if (_activeChatRequest == null) {
            return _buildChatsList(state, requests, user, isCompact: false);
          } else {
            return Column(
              children: [
                Container(
                  height: 165,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.04))),
                  ),
                  child: _buildChatsList(state, requests, user, isCompact: true),
                ),
                Expanded(
                  child: _buildChatDetails(state, user),
                ),
              ],
            );
          }
        } else {
          // Desktop Horizontal Side-by-Side Row
          return Row(
            children: [
              Container(
                width: 320,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Colors.white.withOpacity(0.04))),
                ),
                child: _buildChatsList(state, requests, user, isCompact: false),
              ),
              Expanded(
                child: _activeChatRequest == null
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey),
                            SizedBox(height: 12),
                            Text("Select a request chat thread to review details.", style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      )
                    : _buildChatDetails(state, user),
              )
            ],
          );
        }
      },
    );
  }

  Widget _buildChatsList(AppState state, List<RequestModel> requests, User? user, {required bool isCompact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: isCompact ? 10 : 20),
          child: Text(
            "Lookup Chats", 
            style: TextStyle(
              color: Colors.white, 
              fontWeight: FontWeight.bold, 
              fontSize: isCompact ? 14 : 17
            )
          ),
        ),
        Expanded(
          child: requests.isEmpty
              ? const Center(child: Text("No lookups logged yet.", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: requests.length,
                  itemBuilder: (context, index) {
                    final req = requests[index];
                    final isSelected = _activeChatRequest?.id == req.id;
                    return Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        dense: isCompact,
                        onTap: () => _loadRequestChat(req),
                        selected: isSelected,
                        selectedTileColor: const Color(0xFF1E293B),
                        leading: CircleAvatar(
                          radius: isCompact ? 14 : 18,
                          backgroundColor: _getStatusColor(req.status).withOpacity(0.15),
                          child: Icon(Icons.location_searching, color: _getStatusColor(req.status), size: isCompact ? 14 : 18),
                        ),
                        title: Text(
                          req.mobileNumber, 
                          style: TextStyle(
                            color: Colors.white, 
                            fontWeight: FontWeight.bold, 
                            fontSize: isCompact ? 12.5 : 14
                          )
                        ),
                        subtitle: Text(
                          "${req.officerName.isNotEmpty ? req.officerName : (req.officerDetails?.fullName ?? 'Officer')} \u2022 ${req.tspDetails?.name ?? state.tsps.firstWhere((t) => t.id == req.tspId, orElse: () => state.tsps.isNotEmpty ? state.tsps.first : TSPProvider(id: 0, name: 'Unknown TSP', code: '', contactEmail: '', mobileNumber: '', inboundNumber: '', isDefault: false, isActive: false)).name}", 
                          style: TextStyle(color: Colors.grey[400], fontSize: isCompact ? 10 : 11)
                        ),
                        trailing: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _getStatusColor(req.status),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        )
      ],
    );
  }

  Widget _buildChatDetails(AppState state, User? user) {
    if (_activeChatRequest == null) return const SizedBox.shrink();
    return Column(
      children: [
        // Chat Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.04))),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (_activeChatRequest!.ticketId.isNotEmpty) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.indigoAccent.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _activeChatRequest!.ticketId,
                              style: const TextStyle(color: Colors.indigoAccent, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            "Request #${_activeChatRequest!.id} - ${_activeChatRequest!.mobileNumber}",
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Submitted by: ${_selectedChatOfficer?.fullName ?? 'Officer'}${_activeChatRequest!.crNo.isNotEmpty ? ' • CR No: ${_activeChatRequest!.crNo}' : ''}${_activeChatRequest!.stationName.isNotEmpty ? ' • Station: ${_activeChatRequest!.stationName}' : ''}",
                      style: TextStyle(color: Colors.grey[400], fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_activeChatRequest!.subject.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        "Subject: ${_activeChatRequest!.subject}",
                        style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _buildStatusTag(_activeChatRequest!.status, tspName: _activeChatRequest!.tspDetails?.name),
            ],
          ),
        ),

        // Direct Send mode indicator
        if (state.allowDirectMessaging)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: const Color(0xFF0A1628),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.teal.withOpacity(0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.swap_horiz_rounded, color: Colors.tealAccent, size: 13),
                      const SizedBox(width: 5),
                      Text(
                        'Direct Mode: Messaging TSP (${_activeChatRequest!.tspDetails?.name ?? 'TSP'})',
                        style: const TextStyle(color: Colors.tealAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

        // ── All status banners — compact, no overflow ──────────────
        // Pending: forward to TSP
        if (_activeChatRequest!.status == RequestStatus.PENDING)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.amber.shade900.withOpacity(0.15),
              border: Border(bottom: BorderSide(color: Colors.amber.shade900.withOpacity(0.3))),
            ),
            child: Row(
              children: [
                const Icon(Icons.pending_actions_outlined, color: Colors.amberAccent, size: 18),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Awaiting Admin Review. Forward to TSP to begin processing.",
                    style: TextStyle(color: Colors.amberAccent, fontSize: 11.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () async {
                    final success = await state.forwardToTsp(_activeChatRequest!.id);
                    if (success && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("Request forwarded to TSP successfully!")),
                      );
                      setState(() {
                        final updated = state.requests.where((r) => r.id == _activeChatRequest!.id);
                        if (updated.isNotEmpty) _activeChatRequest = updated.first;
                      });
                    }
                  },
                  icon: const Icon(Icons.arrow_forward, size: 13),
                  label: const Text("Forward to TSP", style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6366F1),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                ),
              ],
            ),
          ),

        // TSP Responded: approve & send to officer
        if (_activeChatRequest!.status == RequestStatus.TSP_RESPONDED)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.green.shade900.withOpacity(0.15),
              border: Border(bottom: BorderSide(color: Colors.green.shade900.withOpacity(0.3))),
            ),
            child: Row(
              children: [
                const Icon(Icons.quickreply_outlined, color: Colors.greenAccent, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "TSP Response Received!",
                        style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      if (_activeChatRequest!.response.isNotEmpty)
                        Text(
                          _activeChatRequest!.response,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: () => _showCompleteConfirmation(state, _activeChatRequest!),
                  icon: const Icon(Icons.check_circle_outline, size: 13),
                  label: const Text("Approve & Send", style: TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ],
            ),
          ),

        // Forwarded/Processing: show inbound number and log SMS button
        if (_activeChatRequest!.status == RequestStatus.FORWARDED ||
            _activeChatRequest!.status == RequestStatus.PROCESSING)
          _buildInboundSmsPanel(state, _activeChatRequest!),

        // Message Logs — Expanded fills all remaining space
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(24),
            itemCount: state.chatMessages.length,
            itemBuilder: (context, index) {
              final msg = state.chatMessages[index];
              final isMe = msg.sender == user?.id;
              return _buildAdminChatBubble(state, msg, isMe);
            },
          ),
        ),

        // Chat Input Bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          color: const Color(0xFF1E293B),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                    controller: _messageController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: state.allowDirectMessaging
                          ? 'Message to TSP (${_activeChatRequest?.tspDetails?.name ?? 'TSP'})...'
                          : 'Write a message back to Officer...',
                      hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      filled: true,
                      fillColor: const Color(0xFF0F172A),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                    ),
                  ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _isSending ? null : _sendMessage,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: [Color(0xFF6366F1), Color(0xFF4F46E5)],
                    ),
                  ),
                  child: _isSending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                        )
                      : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }



  Widget _buildDashboardOverviewPanel(AppState state) {
    final stats = state.adminStats;
    final int absentApproved = stats['absent_approved_requests'] ?? 0;
    final int directTsp = stats['direct_tsp_requests'] ?? 0;
    final int pendingReview = stats['pending_requests'] ?? 0;
    final int completedRequests = stats['completed_requests'] ?? 0;

    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Dashboard Overview",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "System metrics, automated routing workflows, and activity logs. Admin Status: ${state.adminStatus.toUpperCase()}",
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => state.refresh(),
                tooltip: "Refresh Stats",
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 4 Premium Metric Cards
          Row(
            children: [
              _buildDashboardMetricCard(
                "Auto Approved Requests", 
                absentApproved.toString(), 
                Colors.greenAccent, 
                Icons.assignment_turned_in_outlined
              ),
              const SizedBox(width: 16),
              _buildDashboardMetricCard(
                "Direct TSP Requests", 
                directTsp.toString(), 
                Colors.blueAccent, 
                Icons.send_and_archive_outlined
              ),
              const SizedBox(width: 16),
              _buildDashboardMetricCard(
                "Pending Admin Review", 
                pendingReview.toString(), 
                Colors.amberAccent, 
                Icons.pending_actions_outlined
              ),
              const SizedBox(width: 16),
              _buildDashboardMetricCard(
                "Completed Requests", 
                completedRequests.toString(), 
                Colors.purpleAccent, 
                Icons.task_alt_outlined
              ),
            ],
          ),
          const SizedBox(height: 28),

          // Audit Logs Title
          const Text(
            "Audit Trail / Recent Activity Logs",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 12),

          // Audit Logs List
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: state.activityLogs.isEmpty
                  ? const Center(child: Text("No activity logs available.", style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: state.activityLogs.length,
                      itemBuilder: (context, index) {
                        final log = state.activityLogs[index];
                        final isAuditLog = log.action.contains("Audit Log") || log.action.contains("Auto Approval");
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isAuditLog ? const Color(0xFF0F172A).withOpacity(0.4) : Colors.transparent,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isAuditLog ? Colors.indigoAccent.withOpacity(0.2) : Colors.white.withOpacity(0.02),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              CircleAvatar(
                                backgroundColor: (isAuditLog ? Colors.indigoAccent : Colors.grey[700]!).withOpacity(0.15),
                                child: Icon(
                                  isAuditLog ? Icons.verified_user_outlined : Icons.info_outline,
                                  color: isAuditLog ? Colors.indigoAccent : Colors.grey[400],
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          log.action.toUpperCase(),
                                          style: TextStyle(
                                            color: isAuditLog ? Colors.indigoAccent : Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        Text(
                                          DateFormat('dd MMM yyyy, hh:mm a').format(log.timestamp),
                                          style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      log.details ?? 'No details provided.',
                                      style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      "Triggered by: ${log.userName} (${log.userRole})",
                                      style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardMetricCard(String title, String value, Color color, IconData icon) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.04)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(icon, color: color.withOpacity(0.7), size: 18),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                ),
                const SizedBox(width: 6),
                const Text("Active Metric", style: TextStyle(color: Colors.grey, fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminChatBubble(AppState state, ChatMessage msg, bool isMe) {
    final isRequestCard = msg.message.contains("🚨 **New Lookup Request** 🚨");

    if (isRequestCard) {
      final isPending = _activeChatRequest!.status == RequestStatus.PENDING;
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          padding: const EdgeInsets.all(18),
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF6366F1).withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.location_searching, color: Color(0xFF6366F1), size: 18),
                  SizedBox(width: 8),
                  Text(
                    "INCOMING REQUEST DATA",
                    style: TextStyle(color: Color(0xFF6366F1), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                msg.message.replaceAll("🚨 **New Lookup Request** 🚨\n\n", ""),
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    DateFormat('hh:mm a').format(msg.timestamp),
                    style: TextStyle(color: Colors.grey[500], fontSize: 9),
                  ),
                  if (isPending)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ElevatedButton(
                          onPressed: () async {
                            final success = await state.forwardToTsp(_activeChatRequest!.id);
                            if (success) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text("Request forwarded to TSP successfully!")),
                              );
                              setState(() {
                                final updated = state.requests.where((r) => r.id == _activeChatRequest!.id);
                                if (updated.isNotEmpty) _activeChatRequest = updated.first;
                              });
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text("Forward to TSP", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: () => _showReviewConfirmation(state, _activeChatRequest!, "REJECT"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                          child: const Text("Reject", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    )
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF6366F1).withOpacity(0.15) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          border: Border.all(color: isMe ? const Color(0xFF6366F1).withOpacity(0.2) : Colors.white.withOpacity(0.04)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                "${msg.senderName} (${msg.senderRole})",
                style: const TextStyle(color: Color(0xFF6366F1), fontSize: 10, fontWeight: FontWeight.bold),
              ),
            if (!isMe) const SizedBox(height: 4),
            Text(
              msg.message,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                DateFormat('hh:mm a').format(msg.timestamp),
                style: TextStyle(color: Colors.grey[500], fontSize: 9),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// ─── Inbound TSP SMS Panel — compact bar ──────────────────────────────────
  Widget _buildInboundSmsPanel(AppState state, RequestModel req) {
    final tsp = req.tspDetails;
    final inboundNumber = (tsp?.inboundNumber != null && tsp!.inboundNumber.isNotEmpty) ? tsp.inboundNumber : '9844281875';
    final hasInbound = inboundNumber.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.teal.shade900.withOpacity(0.12),
        border: Border(
          bottom: BorderSide(color: Colors.tealAccent.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.sms_outlined, color: Colors.tealAccent, size: 17),
          const SizedBox(width: 10),
          Expanded(
            child: hasInbound
                ? RichText(
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: const TextStyle(color: Colors.white70, fontSize: 11.5),
                      children: [
                        const TextSpan(text: "Awaiting TSP SMS • Share: "),
                        TextSpan(
                          text: inboundNumber,
                          style: const TextStyle(
                            color: Colors.tealAccent,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  )
                : const Text(
                    "Awaiting TSP SMS • No inbound number set (configure in Settings)",
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            onPressed: () => _showLogTspSmsDialog(state, req),
            icon: const Icon(Icons.inbox_rounded, size: 13),
            label: const Text("Log TSP SMS", style: TextStyle(fontSize: 11)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ),
    );
  }


  void _showLogTspSmsDialog(AppState state, RequestModel req) {
    final tsp = req.tspDetails;
    final inboundNumber = (tsp?.inboundNumber != null && tsp!.inboundNumber.isNotEmpty) ? tsp.inboundNumber : '9844281875';
    final fromController = TextEditingController(text: tsp?.mobileNumber ?? '');
    final smsBodyController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Row(
            children: [
              const Icon(Icons.sms_outlined, color: Colors.tealAccent, size: 20),
              const SizedBox(width: 10),
              Text(
                "Log Inbound TSP SMS: ${req.mobileNumber}",
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Inbound number info box
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.teal.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.tealAccent.withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Inbound SMS Gateway Number",
                        style: TextStyle(color: Colors.tealAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        inboundNumber.isNotEmpty ? inboundNumber : "Not configured",
                        style: TextStyle(
                          color: inboundNumber.isNotEmpty ? Colors.white : Colors.grey,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "TSP ${tsp?.name ?? 'operator'} sends SMS to this number",
                        style: TextStyle(color: Colors.grey[500], fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: fromController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: "TSP From Number (number that sent the SMS)",
                    labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                    prefixIcon: const Icon(Icons.call_made, color: Colors.blueAccent, size: 18),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: smsBodyController,
                  maxLines: 5,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: "SMS Content (subscriber information from TSP)*",
                    labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                    hintText: "e.g. Status: Active\nName: John Doe\nAddress: ...",
                    hintStyle: TextStyle(color: Colors.grey[600], fontSize: 11),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "This logs the SMS that TSP sent to your inbound number, marking the request as responded.",
                  style: TextStyle(color: Colors.grey[500], fontSize: 10.5),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                if (smsBodyController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("SMS content is required.")),
                  );
                  return;
                }
                Navigator.pop(context);
                final success = await state.tspSmsResponse(
                  req.id,
                  fromController.text.trim(),
                  inboundNumber,
                  smsBodyController.text.trim(),
                );
                if (success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("✅ TSP SMS response logged successfully!")),
                  );
                  setState(() {
                    final updated = state.requests.where((r) => r.id == req.id);
                    if (updated.isNotEmpty) _activeChatRequest = updated.first;
                  });
                }
              },
              icon: const Icon(Icons.save_rounded, size: 15),
              label: const Text("Log SMS Response"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal.shade600,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }

  void _showReviewConfirmation(AppState state, RequestModel req, String action) {
    final remarksController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Text(
            "${action == 'APPROVE' ? 'Approve' : 'Reject'} Lookup: ${req.mobileNumber}",
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                action == 'APPROVE' 
                  ? "Are you sure you want to approve this lookup request? Approving it will automatically forward it to the Telecom Service Provider (TSP)."
                  : "Are you sure you want to reject this request? Please provide remarks explaining the reason for rejection.",
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: remarksController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Remarks / Review Notes",
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _reviewRequest(state, req, action, remarksController.text.trim());
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: action == 'APPROVE' ? Colors.green : Colors.red,
              ),
              child: const Text("Confirm"),
            ),
          ],
        );
      },
    );
  }

  // ─── Menu Panel 2: All Requests ──────────────────────────────────────────
  Widget _buildAllRequestsPanel(AppState state) {
    final filteredRequests = state.requests.where((req) {
      if (_allRequestsTspFilter == "All") return true;
      final tspName = req.tspDetails?.name ?? '';
      final filter = _allRequestsTspFilter.toLowerCase();
      final name = tspName.toLowerCase();
      if (filter == 'airtel') return name.contains('airtel');
      if (filter == 'jio') return name.contains('jio');
      if (filter == 'vi') return name.contains('vi') || name.contains('vodafone');
      if (filter == 'bsnl') return name.contains('bsnl');
      return false;
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Received Requests", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 20),
          
          // Dropdown Filter Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Filter by Telecom Provider:",
                style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _allRequestsTspFilter,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    icon: const Icon(Icons.filter_list_rounded, color: Colors.grey, size: 16),
                    items: ["All", "Airtel", "Jio", "Vi", "BSNL"].map((tsp) {
                      return DropdownMenuItem<String>(
                        value: tsp,
                        child: Text(tsp),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _allRequestsTspFilter = val;
                        });
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          Expanded(
            child: filteredRequests.isEmpty
                ? const Center(child: Text("No requests match this filter.", style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: filteredRequests.length,
                    itemBuilder: (context, index) {
                      final req = filteredRequests[index];
                      final isPending = req.status == RequestStatus.PENDING;
                      final isForwarded = req.status == RequestStatus.FORWARDED;
                      final isProcessing = req.status == RequestStatus.PROCESSING;
                      final isResponded = req.status == RequestStatus.TSP_RESPONDED;
                      final isCompleted = req.status == RequestStatus.COMPLETED;
                      
                      // Determine status text and color
                      String statusText;
                      Color statusColor;
                      Color statusBgColor;
                      
                      if (isPending) {
                        statusText = "Awaiting Approval";
                        statusColor = Colors.amber;
                        statusBgColor = Colors.amber.withOpacity(0.1);
                      } else if (isForwarded) {
                        statusText = "Forwarded to TSP";
                        statusColor = Colors.blue;
                        statusBgColor = Colors.blue.withOpacity(0.1);
                      } else if (isProcessing) {
                        statusText = "Processing (TSP Acknowledged)";
                        statusColor = Colors.orange;
                        statusBgColor = Colors.orange.withOpacity(0.1);
                      } else if (isResponded) {
                        statusText = "TSP Response Received";
                        statusColor = Colors.purple;
                        statusBgColor = Colors.purple.withOpacity(0.1);
                      } else if (isCompleted) {
                        statusText = "Completed & Sent to Officer";
                        statusColor = Colors.green;
                        statusBgColor = Colors.green.withOpacity(0.1);
                      } else {
                        statusText = "Unknown";
                        statusColor = Colors.grey;
                        statusBgColor = Colors.grey.withOpacity(0.1);
                      }
                      
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.04)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6366F1).withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    req.ticketId.isNotEmpty ? req.ticketId : 'TKT-${req.id.toString().padLeft(6, "0")}',
                                    style: const TextStyle(
                                      color: Color(0xFF818CF8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${req.createdAt.day}/${req.createdAt.month}/${req.createdAt.year}',
                                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('MOBILE NUMBER', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(req.mobileNumber, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('SELECTED TSP', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Row(
                                        children: [
                                          const Icon(Icons.cell_tower, color: Colors.blueAccent, size: 12),
                                          const SizedBox(width: 4),
                                          Text(req.tspDetails?.name ?? 'TSP Provider', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Text('OFFICER & STATION', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                            const SizedBox(height: 2),
                            Text(
                              '${req.officerName} • ${req.stationName.isNotEmpty ? req.stationName : "N/A"}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            const SizedBox(height: 10),
                            const Text('DETAILS', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                            const SizedBox(height: 2),
                            Text(
                              '${req.subject.isNotEmpty ? req.subject : "Lookup Request"}: ${req.message.isNotEmpty ? req.message : (req.reason.isNotEmpty ? req.reason : "No details provided")}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            
                            // Show TSP Response if available!
                            if (req.tspResponse != null || req.response.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              const Text('TSP RESPONSE', style: TextStyle(color: Colors.greenAccent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                              const SizedBox(height: 2),
                              Text(
                                req.response.isNotEmpty ? req.response : (req.tspResponse?.details ?? "No response details"),
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                              ),
                            ],
                            
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: statusBgColor,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: statusColor.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Text(
                                    statusText,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                if (isPending)
                                  ElevatedButton.icon(
                                    onPressed: () async {
                                      final success = await state.forwardToTsp(req.id);
                                      if (success) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text("Request forwarded to TSP successfully!")),
                                        );
                                      }
                                    },
                                    icon: const Icon(Icons.arrow_forward, size: 12),
                                    label: const Text("Forward to TSP", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF6366F1),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      elevation: 0,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTspManagementPage(AppState state, int tspId, String tspName) {
    final tspRequests = state.requests.where((r) => r.tspId == tspId).toList();

    // Compute counts
    final pendingCount = tspRequests.where((r) => r.status == RequestStatus.FORWARDED).length;
    final processingCount = tspRequests.where((r) => r.status == RequestStatus.PROCESSING).length;
    final completedCount = tspRequests.where((r) => r.status == RequestStatus.TSP_RESPONDED || r.status == RequestStatus.COMPLETED).length;

    // Apply filters
    var filteredRequests = tspRequests;
    if (_tspStatusFilter == "Pending") {
      filteredRequests = filteredRequests.where((r) => r.status == RequestStatus.FORWARDED).toList();
    } else if (_tspStatusFilter == "Processing") {
      filteredRequests = filteredRequests.where((r) => r.status == RequestStatus.PROCESSING).toList();
    } else if (_tspStatusFilter == "Completed") {
      filteredRequests = filteredRequests.where((r) => r.status == RequestStatus.TSP_RESPONDED || r.status == RequestStatus.COMPLETED).toList();
    }

    if (_tspSearchQuery.isNotEmpty) {
      filteredRequests = filteredRequests.where((r) =>
        r.mobileNumber.contains(_tspSearchQuery) ||
        r.officerName.toLowerCase().contains(_tspSearchQuery.toLowerCase()) ||
        r.id.toString() == _tspSearchQuery
      ).toList();
    }

    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "$tspName Management",
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      "Monitor and process lookup requests assigned to this provider.",
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          Row(
            children: [
              _buildCountCard("Pending Requests", pendingCount, Colors.amberAccent),
              const SizedBox(width: 16),
              _buildCountCard("Processing Requests", processingCount, Colors.blueAccent),
              const SizedBox(width: 16),
              _buildCountCard("Completed Requests", completedCount, Colors.greenAccent),
            ],
          ),
          const SizedBox(height: 24),

          Row(
            children: [
              Expanded(
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: "Search by Mobile Number or Officer...",
                    hintStyle: TextStyle(color: Colors.grey[500], fontSize: 12),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 18),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onChanged: (val) {
                    setState(() {
                      _tspSearchQuery = val;
                    });
                  },
                ),
              ),
              const SizedBox(width: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _tspStatusFilter,
                    dropdownColor: const Color(0xFF1E293B),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    items: ["All", "Pending", "Processing", "Completed"].map((status) {
                      return DropdownMenuItem<String>(
                        value: status,
                        child: Text(status),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() {
                          _tspStatusFilter = val;
                        });
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: 1180,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        color: const Color(0xFF0F172A).withOpacity(0.4),
                        child: Row(
                          children: [
                            _tableHeaderCell("ID", 50),
                            _tableHeaderCell("Officer Name", 130),
                            _tableHeaderCell("Mobile Number", 120),
                            _tableHeaderCell("Station Name", 120),
                            _tableHeaderCell("CR Number", 100),
                            _tableHeaderCell("Remarks", 130),
                            _tableHeaderCell("Request Date", 160),
                            _tableHeaderCell("Status", 130),
                            _tableHeaderCell("Actions", 140),
                          ],
                        ),
                      ),

                      Expanded(
                        child: filteredRequests.isEmpty
                            ? const Center(child: Text("No requests match this filter.", style: TextStyle(color: Colors.grey)))
                            : ListView.builder(
                                itemCount: filteredRequests.length,
                                itemBuilder: (context, index) {
                                  final req = filteredRequests[index];
                                  return Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                    decoration: BoxDecoration(
                                      border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.03))),
                                    ),
                                    child: Row(
                                      children: [
                                        _tableCell("#${req.id}", 50, color: Colors.grey),
                                        _tableCell(req.officerName.isNotEmpty ? req.officerName : (req.officerDetails?.fullName ?? 'Officer'), 130),
                                        _tableCell(req.mobileNumber, 120, fontWeight: FontWeight.bold),
                                        SizedBox(
                                          width: 120,
                                          child: Text(
                                            req.stationName.isNotEmpty ? req.stationName.replaceAll(RegExp(r'\s+station', caseSensitive: false), '\nstation') : '—',
                                            style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                            maxLines: 2,
                                            softWrap: true,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        _tableCell(req.crNo.isNotEmpty ? req.crNo : '—', 100, color: const Color(0xFF818CF8)),
                                        _tableCell(req.remarks.isNotEmpty ? req.remarks : 'None', 130),
                                        _tableCell(DateFormat('dd MMM yyyy, hh:mm').format(req.createdAt), 160),
                                        SizedBox(
                                          width: 130,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerLeft,
                                            child: _buildStatusTag(req.status, tspName: req.tspDetails?.name),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 140,
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            alignment: Alignment.centerRight,
                                            child: _buildTspActions(state, req),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableHeaderCell(String label, double width) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.grey,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _tableCell(String text, double width, {Color? color, FontWeight? fontWeight}) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        style: TextStyle(
          color: color ?? Colors.white,
          fontSize: 12.5,
          fontWeight: fontWeight,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildCountCard(String title, int count, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.15)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: TextStyle(color: Colors.grey[400], fontSize: 12, fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),
            Text(
              count.toString(),
              style: TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTspActions(AppState state, RequestModel req) {
    if (req.status == RequestStatus.FORWARDED) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.purple.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.purpleAccent.withOpacity(0.3)),
        ),
        child: const Text(
          "Awaiting TSP",
          style: TextStyle(color: Colors.purpleAccent, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      );
    } else if (req.status == RequestStatus.PENDING) {
      return ElevatedButton.icon(
        onPressed: () async {
          final success = await state.forwardToTsp(req.id);
          if (success) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Request forwarded to TSP successfully!")),
              );
            }
          }
        },
        icon: const Icon(Icons.arrow_forward, size: 12),
        label: const Text("Forward to TSP", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6366F1),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    } else if (req.status == RequestStatus.PROCESSING) {
      return ElevatedButton.icon(
        onPressed: () => _showTspResponseDialog(state, req),
        icon: const Icon(Icons.send_rounded, size: 12),
        label: const Text("Send Response", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green.shade600,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    } else if (req.status == RequestStatus.TSP_RESPONDED || req.status == RequestStatus.COMPLETED) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.green.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
        ),
        child: const Text(
          "✓ Response Submitted",
          style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      );
    } else if (req.status == RequestStatus.REJECTED) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.red.withOpacity(0.1),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
        ),
        child: const Text(
          "✗ Rejected",
          style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  void _showTspResponseDialog(AppState state, RequestModel req) {
    final responseController = TextEditingController();
    final notesController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: Text(
            "Submit TSP Response: ${req.mobileNumber}",
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: responseController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Response Details (Subscriber Info)*",
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: notesController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Internal Notes / Remarks (Optional)",
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                if (responseController.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Response details are required.")),
                  );
                  return;
                }
                Navigator.pop(context);
                final success = await state.tspRespond(
                  req.id,
                  responseController.text.trim(),
                  notes: notesController.text.trim(),
                );
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Response submitted to admin successfully!")),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text("Submit Response"),
            ),
          ],
        );
      },
    );
  }

  void _showCompleteConfirmation(AppState state, RequestModel req) {
    final remarksController = TextEditingController(text: "Approved. Information sent.");
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          title: const Text(
            "Approve Response & Complete Request",
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Verify the subscriber information. You can add admin remarks or instructions before forwarding it to the Field Officer.",
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: remarksController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  labelText: "Admin Remarks (Optional)",
                  labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                final success = await state.adminComplete(req.id, remarksController.text.trim());
                if (success) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("Response approved and sent to officer!")),
                  );
                  setState(() {
                    final updated = state.requests.where((r) => r.id == req.id);
                    if (updated.isNotEmpty) _activeChatRequest = updated.first;
                  });
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
              child: const Text("Approve & Send"),
            ),
          ],
        );
      },
    );
  }

  Widget _buildRequestAction(AppState state, RequestModel req) {
    if (req.status == RequestStatus.PENDING) {
      return ElevatedButton.icon(
        onPressed: () async {
          final success = await state.forwardToTsp(req.id);
          if (success) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Request forwarded to TSP successfully!")),
            );
          }
        },
        icon: const Icon(Icons.arrow_forward, size: 12),
        label: const Text("Forward to TSP", style: TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF6366F1),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    } else if (req.status == RequestStatus.TSP_RESPONDED) {
      return ElevatedButton.icon(
        onPressed: () => _showCompleteConfirmation(state, req),
        icon: const Icon(Icons.check, size: 12),
        label: const Text("Approve Response", style: TextStyle(fontSize: 11)),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green.shade600,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      );
    } else {
      return Text(
        _getStatusString(req.status),
        style: TextStyle(color: Colors.grey[500], fontSize: 11, fontWeight: FontWeight.bold),
      );
    }
  }

  Widget _buildFieldOfficerManagementPanel(AppState state) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Field Officer Management",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
                SizedBox(height: 2),
                Text(
                  "Register new officers and manage their access permissions.",
                  style: TextStyle(color: Colors.grey, fontSize: 11.5),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ],
            ),
            const SizedBox(height: 20),

            // ── Card 1: Register Form ─────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Register New Field Officer",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14.5),
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _officerFirstNameController,
                    label: "Full Name *",
                    hint: "Ranjeet Singh",
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _officerEmailController,
                    label: "Email Address *",
                    hint: "officer@smstsp.com",
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _officerPasswordController,
                    label: "Password *",
                    hint: "••••••••",
                    obscureText: true,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isRegisteringOfficer ? null : () async {
                        final fullName = _officerFirstNameController.text.trim();
                        final email = _officerEmailController.text.trim();
                        final password = _officerPasswordController.text;

                        if (fullName.isEmpty || email.isEmpty || password.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Name, Email, and Password are required fields.")),
                          );
                          return;
                        }

                        final nameParts = fullName.split(' ');
                        final firstName = nameParts.isNotEmpty ? nameParts[0] : '';
                        final lastName = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '';
                        final username = email.split('@')[0];

                        setState(() => _isRegisteringOfficer = true);
                        final success = await state.createFieldOfficer(
                          username: username,
                          email: email,
                          password: password,
                          firstName: firstName,
                          lastName: lastName,
                        );
                        setState(() => _isRegisteringOfficer = false);

                        if (success) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Field Officer registered successfully!")),
                            );
                          }
                          _officerEmailController.clear();
                          _officerPasswordController.clear();
                          _officerFirstNameController.clear();
                        } else {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("Failed to register Field Officer. Email may already be taken.")),
                            );
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                      child: _isRegisteringOfficer
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text("Register Field Officer", style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Card 2: Officer List ──────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Field Officers & Access Permissions",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14.5),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "Grant or revoke direct forwarding and daily limit permissions.",
                    style: TextStyle(color: Colors.grey, fontSize: 11),
                  ),
                  const SizedBox(height: 12),
                  state.fieldOfficers.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(child: Text("No field officers registered.", style: TextStyle(color: Colors.grey))),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: state.fieldOfficers.length,
                          separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.05), height: 1),
                          itemBuilder: (context, index) {
                            final officer = state.fieldOfficers[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // ── Name + badges row ─────────────────
                                  Row(
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: const Color(0xFF6366F1).withOpacity(0.12),
                                        child: const Icon(Icons.person, color: Color(0xFF6366F1), size: 18),
                                      ),
                                      const SizedBox(width: 10),
                                      // FIX: Expanded so name never overflows
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              officer.fullName,
                                              style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              officer.email,
                                              style: const TextStyle(color: Colors.grey, fontSize: 11),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      // Limit badge
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: officer.bypassDailyLimit
                                              ? Colors.blue.withOpacity(0.15)
                                              : Colors.amber.withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: officer.bypassDailyLimit
                                                ? Colors.blue.withOpacity(0.3)
                                                : Colors.amber.withOpacity(0.3),
                                          ),
                                        ),
                                        child: Text(
                                          officer.bypassDailyLimit ? "No Limit" : "Max 5/Day",
                                          style: TextStyle(
                                            color: officer.bypassDailyLimit ? Colors.blueAccent : Colors.amberAccent,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      if (officer.bypassRequested && !officer.bypassDailyLimit) ...[
                                        const SizedBox(width: 4),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFEF4444).withOpacity(0.15),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(
                                              color: const Color(0xFFEF4444).withOpacity(0.3),
                                            ),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.notification_important_rounded, color: Color(0xFFF87171), size: 10),
                                              SizedBox(width: 2),
                                              Text(
                                                "Bypass Requested",
                                                style: TextStyle(
                                                  color: Color(0xFFF87171),
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  // ── Switches row ───────────────────────
                                  Row(
                                    children: [
                                      const SizedBox(width: 46), // align under name
                                      Expanded(
                                        child: Row(
                                          children: [
                                            const Icon(Icons.all_inclusive, color: Colors.grey, size: 13),
                                            const SizedBox(width: 4),
                                            Expanded(
                                              child: Text(
                                                "Allow > 5/Day",
                                                style: TextStyle(
                                                  color: officer.bypassRequested && !officer.bypassDailyLimit
                                                      ? Colors.amberAccent
                                                      : Colors.grey,
                                                  fontWeight: officer.bypassRequested && !officer.bypassDailyLimit
                                                      ? FontWeight.bold
                                                      : FontWeight.normal,
                                                  fontSize: 11,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            SizedBox(
                                              height: 24,
                                              child: Switch(
                                                value: officer.bypassDailyLimit,
                                                activeColor: Colors.blue,
                                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                                onChanged: (val) async {
                                                   if (val) {
                                                     final extraController = TextEditingController(text: "5");
                                                     final daysController = TextEditingController(text: "1");
                                                     await showDialog(
                                                       context: context,
                                                       builder: (dialogContext) => AlertDialog(
                                                         backgroundColor: const Color(0xFF1E293B),
                                                         title: const Text("Allow Extra Requests", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                                                         content: Column(
                                                           mainAxisSize: MainAxisSize.min,
                                                           children: [
                                                             const Text("Configure how many extra requests this officer can send and for how many days.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                                                             const SizedBox(height: 16),
                                                             TextField(
                                                               controller: extraController,
                                                               keyboardType: TextInputType.number,
                                                               style: const TextStyle(color: Colors.white),
                                                               decoration: InputDecoration(
                                                                 labelText: "Extra Requests Allowed",
                                                                 labelStyle: const TextStyle(color: Colors.grey),
                                                                 filled: true,
                                                                 fillColor: const Color(0xFF0F172A),
                                                                 border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                                               ),
                                                             ),
                                                             const SizedBox(height: 16),
                                                             TextField(
                                                               controller: daysController,
                                                               keyboardType: TextInputType.number,
                                                               style: const TextStyle(color: Colors.white),
                                                               decoration: InputDecoration(
                                                                 labelText: "Valid For (Days)",
                                                                 labelStyle: const TextStyle(color: Colors.grey),
                                                                 filled: true,
                                                                 fillColor: const Color(0xFF0F172A),
                                                                 border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                                               ),
                                                             ),
                                                           ],
                                                         ),
                                                         actions: [
                                                           TextButton(
                                                             onPressed: () => Navigator.of(dialogContext).pop(),
                                                             child: const Text("Cancel"),
                                                           ),
                                                           ElevatedButton(
                                                             onPressed: () {
                                                               final extra = int.tryParse(extraController.text.trim()) ?? 5;
                                                               final days = int.tryParse(daysController.text.trim()) ?? 1;
                                                               state.toggleOfficerBypassLimit(
                                                                 officer.id,
                                                                 true,
                                                                 extraRequestsLimit: extra,
                                                                 bypassDays: days,
                                                               );
                                                               Navigator.of(dialogContext).pop();
                                                             },
                                                             child: const Text("Allow"),
                                                           ),
                                                         ],
                                                       ),
                                                     );
                                                   } else {
                                                     state.toggleOfficerBypassLimit(officer.id, false);
                                                   }
                                                 },
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }


  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscureText,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
            filled: true,
            fillColor: const Color(0xFF0F172A),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF6366F1)),
            ),
          ),
        ),
      ],
    );
  }

  // ─── Menu Panel 4: System Config (Legacy) ────────────────────────────────
  Widget _buildSystemConfigPanel(AppState state) {
    return Padding(
      padding: const EdgeInsets.all(28.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("System Settings & Logs", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
          const SizedBox(height: 6),
          const Text("Configure TSP mobile numbers, audit logs, and system automation permissions.", style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 24),
          
          Row(
            children: [
              _buildTabHeader("General Settings", 0),
              const SizedBox(width: 16),
              _buildTabHeader("TSP Configuration", 1),
              const SizedBox(width: 16),
              _buildTabHeader("SMS & Response Logs", 2),
            ],
          ),
          const SizedBox(height: 24),
          
          Expanded(
            child: _settingsTabIndex == 0
                ? _buildGeneralSettingsTab(state)
                : _settingsTabIndex == 1
                    ? _buildTspConfigTab(state)
                    : _buildSmsLogsTab(state),
          )
        ],
      ),
    );
  }

  Widget _buildTabHeader(String text, int index) {
    final isSelected = _settingsTabIndex == index;
    return InkWell(
      onTap: () => setState(() => _settingsTabIndex = index),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: isSelected ? Colors.transparent : Colors.white.withOpacity(0.04)),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey[400],
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralSettingsTab(AppState state) {
    if (_adminMobileNumberController.text.isEmpty && state.adminMobileNumber.isNotEmpty) {
      _adminMobileNumberController.text = state.adminMobileNumber;
    }
    final autoApprovalEnabled = state.adminStats['auto_approval_mode'] ?? false;
    final autoRoutingEnabled = state.adminStats['auto_routing_mode'] ?? true;
    return Column(
      children: [
        Material(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Automated Workflows", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Global Auto-Approval Mode", style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text("If active, lookup requests bypass admin review and are sent directly to TSPs.", style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                  trailing: Switch(
                    value: autoApprovalEnabled,
                    activeColor: const Color(0xFF6366F1),
                    onChanged: (value) => state.toggleAutoApproval(value),
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.05)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Enable Automatic TSP Routing", style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text("If active, newly created requests route automatically to target TSP queues.", style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                  trailing: Switch(
                    value: autoRoutingEnabled,
                    activeColor: const Color(0xFF6366F1),
                    onChanged: (value) => state.toggleAutoRouting(value),
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.05)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Enable Admin Absent Mode", style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text("When Admin is offline, requests are automatically approved and forwarded to the selected TSP.", style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                  trailing: Switch(
                    value: state.adminAbsentMode,
                    activeColor: const Color(0xFF6366F1),
                    onChanged: (value) => state.toggleAdminAbsentMode(value),
                  ),
                ),
                 Divider(color: Colors.white.withOpacity(0.05)),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Direct Send: Admin to TSP & TSP to Admin", style: TextStyle(color: Colors.white, fontSize: 14)),
                  subtitle: const Text("Requests route directly to TSPs, and replies route back to the admin dashboard (Admin manually forwards to officers).", style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                  trailing: Switch(
                    value: state.allowDirectForwarding,
                    activeColor: const Color(0xFF6366F1),
                    onChanged: (value) => state.toggleAllowDirectForwarding(value),
                  ),
                ),
                Divider(color: Colors.white.withOpacity(0.05)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Admin Mobile Number", style: TextStyle(color: Colors.white, fontSize: 14)),
                            SizedBox(height: 4),
                            Text("Configure the number TSPs should send responses to.", style: TextStyle(color: Colors.grey, fontSize: 11.5)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 200,
                        child: TextFormField(
                          controller: _adminMobileNumberController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          keyboardType: TextInputType.phone,
                          decoration: InputDecoration(
                            hintText: "e.g., 9844281875",
                            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            suffixIcon: IconButton(
                              icon: const Icon(Icons.save, color: Color(0xFF6366F1), size: 20),
                              onPressed: () async {
                                final number = _adminMobileNumberController.text.trim();
                                if (number.isNotEmpty) {
                                  await state.updateAdminMobileNumber(number);
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text("Admin mobile number updated: $number")),
                                    );
                                  }
                                }
                              },
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderSide: const BorderSide(color: Color(0xFF6366F1)),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        // Officer list permissions
        Expanded(
          child: Material(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.04)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text("Field Officers Direct Permissions", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 4),
                  const Text("Grant or revoke direct TSP forward permissions per officer.", style: TextStyle(color: Colors.grey, fontSize: 11)),
                  const SizedBox(height: 16),
                  
                  Expanded(
                    child: state.fieldOfficers.isEmpty
                      ? const Center(child: Text("No field officers registered.", style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: state.fieldOfficers.length,
                          itemBuilder: (context, index) {
                            final officer = state.fieldOfficers[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                backgroundColor: const Color(0xFF6366F1).withOpacity(0.1),
                                child: const Icon(Icons.person, color: Color(0xFF6366F1), size: 18),
                              ),
                              title: Row(
                                children: [
                                  Text(officer.fullName, style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: officer.directForwardAllowed
                                          ? Colors.green.withOpacity(0.15)
                                          : Colors.grey.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: officer.directForwardAllowed
                                            ? Colors.green.withOpacity(0.3)
                                            : Colors.grey.withOpacity(0.3),
                                      ),
                                    ),
                                    child: Text(
                                      officer.directForwardAllowed ? "Full Access" : "Standard Access",
                                      style: TextStyle(
                                        color: officer.directForwardAllowed ? Colors.greenAccent : Colors.grey,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: officer.bypassDailyLimit
                                          ? Colors.blue.withOpacity(0.15)
                                          : Colors.amber.withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: officer.bypassDailyLimit
                                            ? Colors.blue.withOpacity(0.3)
                                            : Colors.amber.withOpacity(0.3),
                                      ),
                                    ),
                                    child: Text(
                                      officer.bypassDailyLimit ? "No Limit" : "Max 5/Day",
                                      style: TextStyle(
                                        color: officer.bypassDailyLimit ? Colors.blueAccent : Colors.amberAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                "${officer.email} • ${officer.directForwardAllowed ? 'Direct Forward' : 'Needs Review'} • ${officer.bypassDailyLimit ? (officer.isBypassActive ? (officer.extraRequestsLimit > 0 ? '+${officer.extraRequestsLimit} Req/Day' : 'Unlimited') : 'Bypass (Expired)') : 'Max 5/Day'}",
                                style: const TextStyle(color: Colors.grey, fontSize: 11),
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Text("Direct Forward", style: TextStyle(color: Colors.grey, fontSize: 9)),
                                      SizedBox(
                                        height: 24,
                                        child: Switch(
                                          value: officer.directForwardAllowed,
                                          activeColor: const Color(0xFF6366F1),
                                          onChanged: (val) => state.toggleOfficerPermission(officer.id, val),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 16),
                                  Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Text("Allow > 5 Req", style: TextStyle(color: Colors.grey, fontSize: 9)),
                                      SizedBox(
                                        height: 24,
                                        child: Switch(
                                          value: officer.bypassDailyLimit,
                                          activeColor: Colors.blue,
                                          onChanged: (val) async {
                                            if (val) {
                                              final extraController = TextEditingController(text: "5");
                                              final daysController = TextEditingController(text: "1");
                                              
                                              await showDialog(
                                                context: context,
                                                builder: (dialogContext) => AlertDialog(
                                                  backgroundColor: const Color(0xFF1E293B),
                                                  title: const Text("Allow Extra Requests", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                                                  content: Column(
                                                    mainAxisSize: MainAxisSize.min,
                                                    children: [
                                                      const Text("Configure how many extra requests this officer can send and for how many days.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                                                      const SizedBox(height: 16),
                                                      TextField(
                                                        controller: extraController,
                                                        keyboardType: TextInputType.number,
                                                        style: const TextStyle(color: Colors.white),
                                                        decoration: InputDecoration(
                                                          labelText: "Extra Requests Allowed",
                                                          labelStyle: const TextStyle(color: Colors.grey),
                                                          filled: true,
                                                          fillColor: const Color(0xFF0F172A),
                                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                                        ),
                                                      ),
                                                      const SizedBox(height: 16),
                                                      TextField(
                                                        controller: daysController,
                                                        keyboardType: TextInputType.number,
                                                        style: const TextStyle(color: Colors.white),
                                                        decoration: InputDecoration(
                                                          labelText: "Valid For (Days)",
                                                          labelStyle: const TextStyle(color: Colors.grey),
                                                          filled: true,
                                                          fillColor: const Color(0xFF0F172A),
                                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () => Navigator.of(dialogContext).pop(),
                                                      child: const Text("Cancel"),
                                                    ),
                                                    ElevatedButton(
                                                      onPressed: () {
                                                        final extra = int.tryParse(extraController.text.trim()) ?? 5;
                                                        final days = int.tryParse(daysController.text.trim()) ?? 1;
                                                        state.toggleOfficerBypassLimit(
                                                          officer.id, 
                                                          true, 
                                                          extraRequestsLimit: extra, 
                                                          bypassDays: days
                                                        );
                                                        Navigator.of(dialogContext).pop();
                                                      },
                                                      child: const Text("Allow"),
                                                    ),
                                                  ],
                                                ),
                                              );
                                            } else {
                                              state.toggleOfficerBypassLimit(officer.id, false);
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                  )
                ],
              ),
            ),
          ),
        )
      ],
    );
  }

  Widget _buildTspConfigTab(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("TSP Mobile Numbers", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                SizedBox(height: 4),
                Text("Configure operator numbers, default states, and active flags.", style: TextStyle(color: Colors.grey, fontSize: 11)),
              ],
            ),
            ElevatedButton.icon(
              onPressed: () => _showTspFormDialog(state),
              icon: const Icon(Icons.add, size: 14),
              label: const Text("Add TSP", style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: state.tsps.isEmpty
              ? const Center(child: Text("No TSPs configured yet.", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: state.tsps.length,
                  itemBuilder: (context, index) {
                    final tsp = state.tsps[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.04)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: (tsp.isDefault ? Colors.green : Colors.grey).withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.cell_tower,
                              color: tsp.isDefault ? Colors.greenAccent : Colors.grey,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        tsp.name,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (tsp.isDefault)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withOpacity(0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text("DEFAULT", style: TextStyle(color: Colors.greenAccent, fontSize: 8, fontWeight: FontWeight.bold)),
                                      ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: (tsp.isActive ? Colors.blue : Colors.red).withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        tsp.isActive ? "ACTIVE" : "INACTIVE",
                                        style: TextStyle(color: tsp.isActive ? Colors.blueAccent : Colors.redAccent, fontSize: 8, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "Outbound: ${tsp.mobileNumber.isNotEmpty ? tsp.mobileNumber : 'Not Set'}",
                                  style: TextStyle(color: Colors.grey[400], fontSize: 12),
                                ),
                                const SizedBox(height: 2),
                                if (tsp.smsTemplate.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 2.0),
                                    child: Row(
                                      children: [
                                        const Text("Template: ", style: TextStyle(color: Colors.grey, fontSize: 11)),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF0F172A),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            tsp.smsTemplate,
                                            style: const TextStyle(
                                              color: Color(0xFF38BDF8),
                                              fontSize: 11,
                                              fontFamily: 'monospace',
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                Row(
                                  children: [
                                    Icon(Icons.inbox_rounded, size: 12, color: tsp.inboundNumber.isNotEmpty ? Colors.greenAccent : Colors.grey[600]),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        "Inbound (TSP sends SMS here): ${tsp.inboundNumber.isNotEmpty ? tsp.inboundNumber : 'Not Set'}",
                                        style: TextStyle(
                                          color: tsp.inboundNumber.isNotEmpty ? Colors.greenAccent.withOpacity(0.85) : Colors.grey[600],
                                          fontSize: 11.5,
                                          fontWeight: tsp.inboundNumber.isNotEmpty ? FontWeight.w600 : FontWeight.normal,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Email: ${tsp.contactEmail}",
                                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.star, color: Colors.amberAccent, size: 20),
                                onPressed: tsp.isDefault ? null : () => state.setDefaultTSP(tsp.id),
                                tooltip: "Set Default",
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                                onPressed: () => _showTspFormDialog(state, existingTsp: tsp),
                                tooltip: "Edit",
                              ),
                              IconButton(
                                icon: Icon(
                                  tsp.isActive ? Icons.visibility_off : Icons.visibility,
                                  color: tsp.isActive ? Colors.orangeAccent : Colors.greenAccent,
                                  size: 20,
                                ),
                                onPressed: () => state.updateTSP(tsp.id, {
                                  'name': tsp.name,
                                  'code': tsp.code,
                                  'contact_email': tsp.contactEmail,
                                  'mobile_number': tsp.mobileNumber,
                                  'is_active': !tsp.isActive,
                                }),
                                tooltip: tsp.isActive ? "Deactivate" : "Activate",
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                                onPressed: () => state.deleteTSP(tsp.id),
                                tooltip: "Delete",
                              ),
                            ],
                          )
                        ],
                      ),
                    );
                  },
                ),
        )
      ],
    );
  }

  void _showTspFormDialog(AppState state, {TSPProvider? existingTsp}) {
    final formKey = GlobalKey<FormState>();
    final nameController = TextEditingController(text: existingTsp?.name ?? '');
    final codeController = TextEditingController(text: existingTsp?.code ?? '');
    final emailController = TextEditingController(text: existingTsp?.contactEmail ?? '');
    final mobileController = TextEditingController(text: existingTsp?.mobileNumber ?? '');
    final inboundController = TextEditingController(text: existingTsp?.inboundNumber ?? '');
    final smsTemplateController = TextEditingController(text: existingTsp?.smsTemplate ?? 'Loc <Number>');
    bool isActive = existingTsp?.isActive ?? true;

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: Text(
                existingTsp == null ? "Add Telecom Service Provider" : "Edit TSP: ${existingTsp.name}",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: nameController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(labelText: "TSP Name (e.g. Airtel)", labelStyle: TextStyle(color: Colors.grey)),
                        validator: (val) => val == null || val.trim().isEmpty ? "Name required" : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: codeController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(labelText: "TSP Code (e.g. AIRTEL)", labelStyle: TextStyle(color: Colors.grey)),
                        validator: (val) => val == null || val.trim().isEmpty ? "Code required" : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: emailController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(labelText: "Contact Email", labelStyle: TextStyle(color: Colors.grey)),
                        validator: (val) => val == null || val.trim().isEmpty ? "Email required" : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: mobileController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: "TSP Outbound Number (Admin sends TO this)",
                          labelStyle: TextStyle(color: Colors.grey),
                          prefixIcon: Icon(Icons.call_made, color: Colors.blueAccent, size: 18),
                        ),
                        keyboardType: TextInputType.phone,
                        validator: (val) => val == null || val.trim().isEmpty ? "Mobile number required" : null,
                      ),
                      const SizedBox(height: 12),
                      // ─── Inbound Number field ───────────────────────────────────────
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.greenAccent.withOpacity(0.3)),
                          color: Colors.green.withOpacity(0.04),
                        ),
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.inbox_rounded, color: Colors.greenAccent, size: 14),
                                const SizedBox(width: 6),
                                const Text(
                                  "Inbound SMS Number",
                                  style: TextStyle(color: Colors.greenAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              "The number TSP operators will SMS responses to (e.g. 9844281875). Share this with the TSP when forwarding.",
                              style: TextStyle(color: Colors.grey, fontSize: 10.5),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: inboundController,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              keyboardType: TextInputType.phone,
                              decoration: const InputDecoration(
                                labelText: "Inbound Number (TSP sends TO this)",
                                labelStyle: TextStyle(color: Colors.grey),
                                prefixIcon: Icon(Icons.call_received, color: Colors.greenAccent, size: 18),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: smsTemplateController,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        minLines: 3,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        decoration: const InputDecoration(
                          labelText: "SMS Template Format",
                          labelStyle: TextStyle(color: Colors.grey),
                          helperText: "Use placeholder <Number> (e.g. Loc <Number>)",
                          helperStyle: TextStyle(color: Colors.grey, fontSize: 10),
                          prefixIcon: Icon(Icons.sms_rounded, color: Colors.greenAccent, size: 18),
                        ),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) return "SMS Template required";
                          if (!val.toLowerCase().contains('<number>')) return "Template must contain '<Number>' placeholder";
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      CheckboxListTile(
                        title: const Text("Is Active", style: TextStyle(color: Colors.white, fontSize: 13)),
                        value: isActive,
                        onChanged: (val) {
                          setDialogState(() {
                            isActive = val ?? true;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    final data = {
                      'name': nameController.text.trim(),
                      'code': codeController.text.trim().toUpperCase(),
                      'contact_email': emailController.text.trim(),
                      'mobile_number': mobileController.text.trim(),
                      'inbound_number': inboundController.text.trim(),
                      'sms_template': smsTemplateController.text.trim(),
                      'is_active': isActive,
                    };
                    bool success;
                    if (existingTsp == null) {
                      success = await state.createTSP(data);
                    } else {
                      success = await state.updateTSP(existingTsp.id, data);
                    }
                    if (success) {
                      Navigator.pop(context);
                    }
                  },
                  child: const Text("Save"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSmsLogsTab(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("SMS Log Auditor", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        const Text("Audit inbound and outbound SMS messages matched with operators and ticket numbers.", style: TextStyle(color: Colors.grey, fontSize: 11)),
        const SizedBox(height: 16),
        Expanded(
          child: state.smsLogs.isEmpty
              ? const Center(child: Text("No SMS logs captured yet.", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: state.smsLogs.length,
                  itemBuilder: (context, index) {
                    final log = state.smsLogs[index];
                    final isSent = log.direction.toUpperCase() == 'SENT';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.04)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: (isSent ? Colors.blue : Colors.green).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      log.direction.toUpperCase(),
                                      style: TextStyle(
                                        color: isSent ? Colors.blueAccent : Colors.greenAccent,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    log.operator,
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    "(${log.tspNumber})",
                                    style: TextStyle(color: Colors.grey[500], fontSize: 11),
                                  ),
                                ],
                              ),
                              Text(
                                DateFormat('dd MMM yyyy, hh:mm a').format(log.timestamp),
                                style: TextStyle(color: Colors.grey[500], fontSize: 10),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              log.message,
                              style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.45),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        )
      ],
    );
  }



  // ─── Helpers ───────────────────────────────────────────────────────────────
  Widget _buildStatusTag(RequestStatus status, {String? tspName}) {
    final color = _getStatusColor(status);
    String label = _getStatusString(status);
    if (status == RequestStatus.FORWARDED && tspName != null) {
      label = "ROUTED TO ${tspName.toUpperCase()} QUEUE";
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          label,
          style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildTspBadge(String name) {
    Color bg;
    Color fg;
    final cleanName = name.toLowerCase().trim();

    if (cleanName.contains('jio')) {
      bg = Colors.blue.shade900.withOpacity(0.2);
      fg = Colors.blueAccent;
    } else if (cleanName.contains('airtel')) {
      bg = Colors.red.shade900.withOpacity(0.2);
      fg = Colors.redAccent;
    } else if (cleanName.contains('vodafone') || cleanName.contains('vi') || cleanName == 'vi (vodafone idea)') {
      bg = Colors.red.shade900.withOpacity(0.2);
      fg = Colors.redAccent;
    } else if (cleanName.contains('bsnl')) {
      bg = Colors.orange.shade900.withOpacity(0.2);
      fg = Colors.orangeAccent;
    } else {
      bg = Colors.grey.shade900.withOpacity(0.2);
      fg = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withOpacity(0.3)),
      ),
      child: Text(
        name,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildTspResponsesPanel(AppState state) {
    var filteredResponses = state.tspResponses;

    if (_responsesTspFilter != "All") {
      filteredResponses = filteredResponses.where((r) {
        final cleanTsp = _responsesTspFilter.toLowerCase();
        final cleanItemTsp = r.tspProvider.toLowerCase();
        if (cleanTsp.contains('vodafone') || cleanTsp == 'vi') {
          return cleanItemTsp.contains('vodafone') || cleanItemTsp.contains('vi');
        }
        return cleanItemTsp.contains(cleanTsp);
      }).toList();
    }

    if (_responsesStatusFilter != "All") {
      filteredResponses = filteredResponses.where((r) => r.status.toLowerCase() == _responsesStatusFilter.toLowerCase()).toList();
    }

    if (_responsesSearchQuery.isNotEmpty) {
      filteredResponses = filteredResponses.where((r) => r.mobileNumber.contains(_responsesSearchQuery)).toList();
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("TSP Replies", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
              SizedBox(height: 2),
              Text("Review & forward TSP replies to officers.", style: TextStyle(color: Colors.grey, fontSize: 11), overflow: TextOverflow.ellipsis),
            ],
          ),
          const SizedBox(height: 20),

          // Filters Row
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: Column(
              children: [

                Row(
                  children: [
                    // Select TSP Dropdown Filter
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _responsesTspFilter,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: "TSP",
                          labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                        ),
                        items: ["All", "Airtel", "Jio", "BSNL", "Vi"].map((tsp) {
                          return DropdownMenuItem(
                            value: tsp,
                            child: Text(tsp, style: const TextStyle(fontSize: 12)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _responsesTspFilter = value ?? "All";
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Status Dropdown Filter
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _responsesStatusFilter,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: "Status",
                          labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                        ),
                        items: ["All", "Pending", "Received", "Reviewed", "Sent to Officer"].map((status) {
                          return DropdownMenuItem(
                            value: status,
                            child: Text(status, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _responsesStatusFilter = value ?? "All";
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          Expanded(
            child: filteredResponses.isEmpty
                ? const Center(child: Text("No TSP replies found.", style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: filteredResponses.length,
                    itemBuilder: (context, index) {
                      final resp = filteredResponses[index];
                      final isSent = resp.status == 'Sent to Officer';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.04)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Text('Req ID: ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                    Text(
                                      resp.requestId != null ? '#${resp.requestId}' : 'N/A',
                                      style: const TextStyle(color: Color(0xFF818CF8), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                Text(
                                  resp.responseDate != null 
                                      ? '${resp.responseDate!.day}/${resp.responseDate!.month}/${resp.responseDate!.year}'
                                      : '${resp.createdAt.day}/${resp.createdAt.month}/${resp.createdAt.year}',
                                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('MOBILE NUMBER', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(resp.mobileNumber, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('TSP PROVIDER', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      _buildTspBadge(resp.tspProvider),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('CIRCLE', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(resp.circle.isNotEmpty ? resp.circle : "—", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('SUBSCRIBER STATUS', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(resp.subscriberStatus.isNotEmpty ? resp.subscriberStatus : "—", style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            const Text('REPLY DETAILS', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                            const SizedBox(height: 2),
                            Text(
                              resp.details.isNotEmpty ? resp.details : "No response details provided",
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: isSent
                                        ? Colors.green.withOpacity(0.1)
                                        : Colors.blueAccent.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSent
                                          ? Colors.green.withOpacity(0.3)
                                          : Colors.blueAccent.withOpacity(0.3),
                                    ),
                                  ),
                                  child: Text(
                                    isSent ? "✓ Forwarded to Officer" : "Ready to Forward",
                                    style: TextStyle(
                                      color: isSent ? Colors.greenAccent : Colors.blueAccent,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.edit_outlined, color: Colors.grey, size: 20),
                                      onPressed: () => _showResponseFormDialog(state, existingResponse: resp),
                                      tooltip: "Edit Response",
                                    ),
                                    const SizedBox(width: 8),
                                    if (!isSent)
                                      ElevatedButton(
                                        onPressed: () async {
                                          final success = await state.sendTSPResponseToOfficer(resp.id);
                                          if (success && mounted) {
                                            setState(() {
                                              if (_activeChatRequest != null && _activeChatRequest!.id == resp.requestId) {
                                                final updated = state.requests.where((r) => r.id == resp.requestId);
                                                if (updated.isNotEmpty) _activeChatRequest = updated.first;
                                              }
                                            });
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text("TSP Response forwarded to Officer successfully!")),
                                            );
                                          }
                                        },
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.green.shade600,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          elevation: 0,
                                        ),
                                        child: const Text("Forward to Officer", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponseStatusTag(String status) {
    Color bg;
    Color fg;

    switch (status.toLowerCase()) {
      case 'pending':
        bg = Colors.amber.shade900.withOpacity(0.2);
        fg = Colors.amberAccent;
        break;
      case 'received':
        bg = Colors.blue.shade900.withOpacity(0.2);
        fg = Colors.blueAccent;
        break;
      case 'reviewed':
        bg = Colors.purple.shade900.withOpacity(0.2);
        fg = Colors.purpleAccent;
        break;
      case 'sent to officer':
        bg = Colors.green.shade900.withOpacity(0.2);
        fg = Colors.greenAccent;
        break;
      default:
        bg = Colors.grey.shade900.withOpacity(0.2);
        fg = Colors.grey;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withOpacity(0.3)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(color: fg, fontSize: 9, fontWeight: FontWeight.bold),
      ),
    );
  }

  void _showResponseFormDialog(AppState state, {TSPResponseModel? existingResponse}) {
    final formKey = GlobalKey<FormState>();
    final reqIdController = TextEditingController(text: existingResponse?.requestId?.toString() ?? '');
    final mobileController = TextEditingController(text: existingResponse?.mobileNumber ?? '');
    final statusController = TextEditingController(text: existingResponse?.subscriberStatus ?? 'Active');
    final circleController = TextEditingController(text: existingResponse?.circle ?? '');
    final notesController = TextEditingController(text: existingResponse?.additionalNotes ?? '');
    
    String selectedTsp = existingResponse?.tspProvider ?? 'Airtel';
    String currentStatus = existingResponse?.status ?? 'Received';
    DateTime? selectedDate = existingResponse?.activationDate ?? DateTime.now();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: Text(
                existingResponse == null ? "Add TSP Response" : "Edit TSP Response #${existingResponse.id}",
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
              content: Container(
                width: 450,
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Request ID
                        TextFormField(
                          controller: reqIdController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Request ID (Optional)",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Mobile Number
                        TextFormField(
                          controller: mobileController,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Mobile Number",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          validator: (val) => val == null || val.trim().isEmpty ? "Mobile number required" : null,
                        ),
                        const SizedBox(height: 16),

                        // TSP Provider Dropdown
                        DropdownButtonFormField<String>(
                          value: ["Airtel", "Jio", "BSNL", "Vodafone Idea (Vi)"].contains(selectedTsp) ? selectedTsp : "Airtel",
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "TSP Provider",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          items: ["Airtel", "Jio", "BSNL", "Vodafone Idea (Vi)"].map((tsp) {
                            return DropdownMenuItem(value: tsp, child: Text(tsp));
                          }).toList(),
                          onChanged: (val) {
                            setDialogState(() {
                              selectedTsp = val ?? "Airtel";
                            });
                          },
                        ),
                        const SizedBox(height: 16),

                        // Subscriber Status
                        TextFormField(
                          controller: statusController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Subscriber Status",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Circle / State
                        TextFormField(
                          controller: circleController,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Circle / State",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Activation Date Picker
                        Row(
                          children: [
                            const Text("Activation Date: ", style: TextStyle(color: Colors.grey, fontSize: 12)),
                            const SizedBox(width: 8),
                            Text(
                              selectedDate != null ? DateFormat('yyyy-MM-dd').format(selectedDate!) : "Select Date",
                              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              onPressed: () async {
                                final picked = await showDatePicker(
                                  context: context,
                                  initialDate: selectedDate ?? DateTime.now(),
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                if (picked != null) {
                                  setDialogState(() {
                                    selectedDate = picked;
                                  });
                                }
                              },
                              icon: const Icon(Icons.calendar_today, size: 14, color: Color(0xFF6366F1)),
                              label: const Text("Choose", style: TextStyle(color: Color(0xFF6366F1), fontSize: 12)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // Additional Notes
                        TextFormField(
                          controller: notesController,
                          maxLines: 3,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Additional Notes",
                            labelStyle: const TextStyle(color: Colors.grey, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
                ),
                // Save Response Button
                ElevatedButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    
                    final Map<String, dynamic> data = {
                      'request': reqIdController.text.isNotEmpty ? int.parse(reqIdController.text) : null,
                      'mobile_number': mobileController.text.trim(),
                      'tsp_provider': selectedTsp,
                      'subscriber_status': statusController.text.trim(),
                      'circle': circleController.text.trim(),
                      'activation_date': selectedDate != null ? "${selectedDate!.year.toString().padLeft(4, '0')}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')}" : null,
                      'additional_notes': notesController.text.trim(),
                      'status': currentStatus,
                    };

                    bool success;
                    if (existingResponse == null) {
                      success = await state.createTSPResponse(data);
                    } else {
                      success = await state.updateTSPResponse(existingResponse.id, data);
                    }

                    if (success) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("TSP Response saved successfully!")),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.indigoAccent,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Save Response"),
                ),
                // Send Response Button
                ElevatedButton(
                  onPressed: () async {
                    if (!formKey.currentState!.validate()) return;
                    
                    final Map<String, dynamic> data = {
                      'request': reqIdController.text.isNotEmpty ? int.parse(reqIdController.text) : null,
                      'mobile_number': mobileController.text.trim(),
                      'tsp_provider': selectedTsp,
                      'subscriber_status': statusController.text.trim(),
                      'circle': circleController.text.trim(),
                      'activation_date': selectedDate != null ? "${selectedDate!.year.toString().padLeft(4, '0')}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')}" : null,
                      'additional_notes': notesController.text.trim(),
                      'status': 'Sent to Officer',
                    };

                    bool success;
                    if (existingResponse == null) {
                      final resp = await state.createTSPResponse(data);
                      if (resp) {
                        final newResp = state.tspResponses.first;
                        success = await state.sendTSPResponseToOfficer(newResp.id);
                      } else {
                        success = false;
                      }
                    } else {
                      await state.updateTSPResponse(existingResponse.id, data);
                      success = await state.sendTSPResponseToOfficer(existingResponse.id);
                    }

                    if (success) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("TSP Response sent to Officer successfully!")),
                      );
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text("Send Response"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Generates an Excel file for all filtered requests and saves it to device storage.
  Future<void> _downloadAllFilteredRequestsExcel(BuildContext ctx, List<RequestModel> requests) async {
    try {
      // Build the workbook
      final excel = xl.Excel.createExcel();
      final defaultSheet = excel.tables.keys.first;
      excel.rename(defaultSheet, 'Filtered Reports');
      final sheet = excel['Filtered Reports'];

      // Header row — styled bold
      final headers = [
        'Station Name',
        'Field Officer Name',
        'CR Number',
        'Date and Time',
        'TSP Provider',
        'Response',
        'TSP Response Date & Time',
      ];
      for (int i = 0; i < headers.length; i++) {
        final cell = sheet.cell(
          xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0),
        );
        cell.value = xl.TextCellValue(headers[i]);
        cell.cellStyle = xl.CellStyle(
          bold: true,
          backgroundColorHex: xl.ExcelColor.fromHexString('#4F46E5'),
          fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
        );
      }

      // Data rows
      for (int rowIndex = 0; rowIndex < requests.length; rowIndex++) {
        final req = requests[rowIndex];
        final officerName = req.officerDetails?.fullName ?? req.officerName;
        final dateTimeStr = DateFormat('dd/MM/yyyy hh:mm a').format(req.createdAt);
        final tspName = req.tspDetails?.name ?? '—';
        final responseVal = req.response.isNotEmpty ? req.response : '—';
        final tspResponseTimeStr = req.tspResponse != null
            ? DateFormat('dd/MM/yyyy hh:mm a').format(req.tspResponse!.timestamp)
            : '—';

        final rowData = [
          req.stationName.isNotEmpty ? req.stationName : '—',
          officerName.isNotEmpty ? officerName : '—',
          req.crNo.isNotEmpty ? req.crNo : '—',
          dateTimeStr,
          tspName,
          responseVal,
          tspResponseTimeStr,
        ];
        for (int colIndex = 0; colIndex < rowData.length; colIndex++) {
          sheet
              .cell(xl.CellIndex.indexByColumnRow(columnIndex: colIndex, rowIndex: rowIndex + 1))
              .value = xl.TextCellValue(rowData[colIndex]);
        }
      }

      // Set column widths
      sheet.setColumnWidth(0, 20);
      sheet.setColumnWidth(1, 22);
      sheet.setColumnWidth(2, 14);
      sheet.setColumnWidth(3, 20);
      sheet.setColumnWidth(4, 18);
      sheet.setColumnWidth(5, 30);
      sheet.setColumnWidth(6, 25);

      // Encode to bytes
      final List<int>? bytes = excel.encode();
      if (bytes == null) throw Exception('Failed to encode Excel');

      // Create filename based on timestamp
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final fileName = 'filtered_report_$timestamp.xlsx';

      Directory saveDir;
      try {
        final downloadsPath = '/storage/emulated/0/Download';
        final downloadsDir = Directory(downloadsPath);
        if (!await downloadsDir.exists()) {
          await downloadsDir.create(recursive: true);
        }
        saveDir = downloadsDir;
      } catch (_) {
        try {
          final extDir = await getExternalStorageDirectory();
          saveDir = extDir ?? await getApplicationDocumentsDirectory();
        } catch (_) {
          saveDir = await getTemporaryDirectory();
        }
      }

      final filePath = '${saveDir.path}/$fileName';
      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);

      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('✅ Filtered Excel report saved!', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                const SizedBox(height: 2),
                Text(filePath, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              ],
            ),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 6),
          ),
        );
      }

    } catch (e) {
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }



  Color _getStatusDotColor(String status) {
    switch (status.toLowerCase()) {
      case 'online':
        return Colors.greenAccent;
      case 'offline':
        return Colors.redAccent;
      case 'away':
        return Colors.orangeAccent;
      default:
        return Colors.greenAccent;
    }
  }

  Color _getStatusColor(RequestStatus status) {
    switch (status) {
      case RequestStatus.PENDING:
        return Colors.amberAccent;
      case RequestStatus.APPROVED:
        return Colors.blueAccent;
      case RequestStatus.PROCESSING:
        return Colors.blueAccent;
      case RequestStatus.REJECTED:
        return Colors.redAccent;
      case RequestStatus.FORWARDED:
        return Colors.purpleAccent;
      case RequestStatus.TSP_RESPONDED:
        return Colors.cyanAccent;
      case RequestStatus.COMPLETED:
        return Colors.greenAccent;
      case RequestStatus.CLOSED:
        return Colors.grey;
    }
  }

  String _getStatusString(RequestStatus status) {
    switch (status) {
      case RequestStatus.PENDING:
        return "PENDING REVIEW";
      case RequestStatus.APPROVED:
        return "APPROVED";
      case RequestStatus.PROCESSING:
        return "PROCESSING";
      case RequestStatus.REJECTED:
        return "REJECTED";
      case RequestStatus.FORWARDED:
        return "FORWARDED TO TSP";
      case RequestStatus.TSP_RESPONDED:
        return "TSP RESPONDED";
      case RequestStatus.COMPLETED:
        return "FORWARDED TO OFFICER";
      case RequestStatus.CLOSED:
        return "CLOSED";
    }
  }

  Widget _buildReportsPanel(AppState state) {
    // 1. Get filtered requests
    var filtered = state.requests;
    
    // TSP filter
    if (_reportsTspFilter != "All") {
      filtered = filtered.where((req) {
        final tspName = req.tspDetails?.name ?? '';
        final filter = _reportsTspFilter.toLowerCase();
        final name = tspName.toLowerCase();
        if (filter == 'airtel') return name.contains('airtel');
        if (filter == 'jio') return name.contains('jio');
        if (filter == 'vi') return name.contains('vi') || name.contains('vodafone');
        if (filter == 'bsnl') return name.contains('bsnl');
        return false;
      }).toList();
    }

    // Officer filter
    if (_reportsOfficerFilter != "All") {
      filtered = filtered.where((req) {
        final officerName = req.officerName;
        return officerName.toLowerCase() == _reportsOfficerFilter.toLowerCase();
      }).toList();
    }

    // Status filter
    if (_reportsStatusFilter != "All") {
      filtered = filtered.where((req) {
        final filter = _reportsStatusFilter.toLowerCase();
        if (filter == 'pending') {
          return req.status == RequestStatus.PENDING;
        }
        if (filter == 'approved') {
          return req.status == RequestStatus.APPROVED;
        }
        if (filter == 'forwarded') {
          return req.status == RequestStatus.FORWARDED || req.status == RequestStatus.PROCESSING;
        }
        if (filter == 'tsp responded') {
          return req.status == RequestStatus.TSP_RESPONDED ||
                 req.status == RequestStatus.COMPLETED ||
                 req.status == RequestStatus.CLOSED;
        }
        return false;
      }).toList();
    }

    // Date filter
    if (_reportsDateFilter != null) {
      filtered = filtered.where((req) {
        return req.createdAt.year == _reportsDateFilter!.year &&
            req.createdAt.month == _reportsDateFilter!.month &&
            req.createdAt.day == _reportsDateFilter!.day;
      }).toList();
    }

    // Week filter
    if (_reportsWeekFilter != "All") {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final weekday = today.weekday;
      final startOfThisWeek = today.subtract(Duration(days: weekday - 1));
      
      filtered = filtered.where((req) {
        final reqDate = DateTime(req.createdAt.year, req.createdAt.month, req.createdAt.day);
        
        if (_reportsWeekFilter == "This Week") {
          return reqDate.isAfter(startOfThisWeek.subtract(const Duration(seconds: 1))) &&
                 reqDate.isBefore(today.add(const Duration(days: 1)));
        } else if (_reportsWeekFilter == "Last Week") {
          final startOfLastWeek = startOfThisWeek.subtract(const Duration(days: 7));
          final endOfLastWeek = startOfThisWeek;
          return reqDate.isAfter(startOfLastWeek.subtract(const Duration(seconds: 1))) &&
                 reqDate.isBefore(endOfLastWeek);
        } else if (_reportsWeekFilter == "2 Weeks Ago") {
          final startOf2WeeksAgo = startOfThisWeek.subtract(const Duration(days: 14));
          final endOf2WeeksAgo = startOfThisWeek.subtract(const Duration(days: 7));
          return reqDate.isAfter(startOf2WeeksAgo.subtract(const Duration(seconds: 1))) &&
                 reqDate.isBefore(endOf2WeeksAgo);
        } else if (_reportsWeekFilter == "3 Weeks Ago") {
          final startOf3WeeksAgo = startOfThisWeek.subtract(const Duration(days: 21));
          final endOf3WeeksAgo = startOfThisWeek.subtract(const Duration(days: 14));
          return reqDate.isAfter(startOf3WeeksAgo.subtract(const Duration(seconds: 1))) &&
                 reqDate.isBefore(endOf3WeeksAgo);
        } else if (_reportsWeekFilter == "4 Weeks Ago") {
          final startOf4WeeksAgo = startOfThisWeek.subtract(const Duration(days: 28));
          final endOf4WeeksAgo = startOfThisWeek.subtract(const Duration(days: 21));
          return reqDate.isAfter(startOf4WeeksAgo.subtract(const Duration(seconds: 1))) &&
                 reqDate.isBefore(endOf4WeeksAgo);
        }
        return true;
      }).toList();
    }

    // Month filter
    if (_reportsMonthFilter != "All") {
      final monthNum = _getMonthNumber(_reportsMonthFilter);
      filtered = filtered.where((req) {
        return req.createdAt.month == monthNum;
      }).toList();
    }

    // Sorting
    filtered = filtered.toList();
    if (_reportsSortOrder == "Date (Newest)") {
      filtered.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else if (_reportsSortOrder == "Date (Oldest)") {
      filtered.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } else if (_reportsSortOrder == "Station Name (A-Z)") {
      filtered.sort((a, b) => a.stationName.toLowerCase().compareTo(b.stationName.toLowerCase()));
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Reports", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      filtered.isEmpty 
                        ? "Filter and download Excel reports for officer requests."
                        : "Showing ${filtered.length} filtered reports.",
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 30,
                height: 30,
                child: ElevatedButton(
                  onPressed: filtered.isEmpty ? null : () => _downloadAllFilteredRequestsExcel(context, filtered),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade800,
                    disabledForegroundColor: Colors.grey.shade600,
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    elevation: 0,
                  ),
                  child: const Icon(Icons.download_rounded, size: 16),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),


          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Filter TSP
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "TSP",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 95,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: _reportsTspFilter,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: ["All", "Airtel", "Jio", "BSNL", "Vi"].map((tsp) {
                            return DropdownMenuItem(value: tsp, child: Text(tsp, style: const TextStyle(fontSize: 11)));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsTspFilter = val ?? "All";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Filter Officer
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "OFFICER",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 125,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: ["All", ...state.fieldOfficers.map((o) => o.fullName).toSet()].contains(_reportsOfficerFilter)
                              ? _reportsOfficerFilter
                              : "All",
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: ["All", ...state.fieldOfficers.map((o) => o.fullName).toSet()].map((name) {
                            return DropdownMenuItem(value: name, child: Text(name, style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsOfficerFilter = val ?? "All";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Filter Status
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "STATUS",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 125,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: _reportsStatusFilter,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: ["All", "Pending", "Approved", "Forwarded", "TSP Responded"].map((status) {
                            return DropdownMenuItem(value: status, child: Text(status, style: const TextStyle(fontSize: 11)));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsStatusFilter = val ?? "All";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Date Picker Filter
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "DATE",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 115,
                        height: 34,
                        child: InkWell(
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _reportsDateFilter ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                              builder: (context, child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: const ColorScheme.dark(
                                      primary: Color(0xFF6366F1),
                                      onPrimary: Colors.white,
                                      surface: Color(0xFF1E293B),
                                      onSurface: Colors.white,
                                    ),
                                    dialogBackgroundColor: const Color(0xFF0F172A),
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            setState(() {
                              _reportsDateFilter = picked;
                            });
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    _reportsDateFilter == null
                                        ? "Select Date"
                                        : DateFormat('dd/MM/yyyy').format(_reportsDateFilter!),
                                    style: const TextStyle(color: Colors.white, fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (_reportsDateFilter != null)
                                  GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _reportsDateFilter = null;
                                      });
                                    },
                                    child: const Icon(Icons.close, size: 12, color: Colors.grey),
                                  )
                                else
                                  const Icon(Icons.calendar_today, size: 11, color: Colors.grey),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Week Filter Dropdown
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "WEEK",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 110,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: _reportsWeekFilter,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: [
                            "All",
                            "This Week",
                            "Last Week",
                            "2 Weeks Ago",
                            "3 Weeks Ago",
                            "4 Weeks Ago"
                          ].map((w) {
                            return DropdownMenuItem(value: w, child: Text(w, style: const TextStyle(fontSize: 11)));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsWeekFilter = val ?? "All";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Month Filter Dropdown
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "MONTH",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 105,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: _reportsMonthFilter,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: [
                            "All",
                            "January",
                            "February",
                            "March",
                            "April",
                            "May",
                            "June",
                            "July",
                            "August",
                            "September",
                            "October",
                            "November",
                            "December"
                          ].map((m) {
                            return DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 11)));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsMonthFilter = val ?? "All";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Sort By Dropdown
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "SORT BY",
                        style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        width: 130,
                        height: 34,
                        child: DropdownButtonFormField<String>(
                          value: _reportsSortOrder,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          isExpanded: true,
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          items: ["Date (Newest)", "Date (Oldest)", "Station Name (A-Z)"].map((s) {
                            return DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 11)));
                          }).toList(),
                          onChanged: (val) {
                            setState(() {
                              _reportsSortOrder = val ?? "Date (Newest)";
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),

                  // Reset Button
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "RESET",
                        style: TextStyle(color: Colors.transparent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                      ),
                      const SizedBox(height: 5),
                      SizedBox(
                        height: 34,
                        child: TextButton.icon(
                          onPressed: () {
                            setState(() {
                              _reportsTspFilter = "All";
                              _reportsOfficerFilter = "All";
                              _reportsStatusFilter = "All";
                              _reportsDateFilter = null;
                              _reportsWeekFilter = "All";
                              _reportsMonthFilter = "All";
                              _reportsSortOrder = "Date (Newest)";
                            });
                          },
                          icon: const Icon(Icons.refresh_rounded, size: 14, color: Colors.redAccent),
                          label: const Text("Reset", style: TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            backgroundColor: Colors.redAccent.withOpacity(0.08),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Requests list / table
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text("No requests match the selected filters.", style: TextStyle(color: Colors.grey)))
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final req = filtered[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.04)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    const Text('Ticket ID: ', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                    Text(
                                      req.ticketId.isNotEmpty ? req.ticketId : 'TKT-${req.id.toString().padLeft(6, "0")}',
                                      style: const TextStyle(color: Color(0xFF818CF8), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${req.createdAt.day}/${req.createdAt.month}/${req.createdAt.year}',
                                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('MOBILE NUMBER', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(req.mobileNumber, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('STATION NAME', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(req.stationName.isNotEmpty ? req.stationName : '—', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('CR NUMBER', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(req.crNo.isNotEmpty ? req.crNo : '—', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('OFFICER NAME', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      Text(req.officerName.isNotEmpty ? req.officerName : (req.officerDetails?.fullName ?? 'Officer'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('SELECTED TSP', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      _buildTspBadge(req.tspDetails?.name ?? 'TSP'),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text('STATUS', style: TextStyle(color: Colors.grey, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                                      const SizedBox(height: 2),
                                      _buildStatusTag(req.status, tspName: req.tspDetails?.name),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
