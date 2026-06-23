import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/app_state.dart';
import '../../models/request.dart';
import '../../models/request_status.dart';
import '../login_screen.dart';

class TSPDashboard extends StatefulWidget {
  const TSPDashboard({super.key});

  @override
  State<TSPDashboard> createState() => _TSPDashboardState();
}

class _TSPDashboardState extends State<TSPDashboard> {
  final TextEditingController _chatController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  bool _isSendingChat = false;

  @override
  void dispose() {
    _chatController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _openChatWithAdmin(BuildContext context, AppState state, RequestModel req) async {
    await state.loadChatMessages(req.id);
    _scrollChatToBottom();
    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _buildChatModal(ctx, state, req),
    );
  }

  Widget _buildChatModal(BuildContext context, AppState stateInit, RequestModel req) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.97,
      builder: (ctx, scrollCtrl) => Consumer<AppState>(
        builder: (ctx, state, _) {
          final user = state.currentUser;
          final adminId = state.adminUserId;
          return Container(
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            child: Column(
              children: [
                // Handle bar
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),

                // Header
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.06))),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: Colors.teal.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.tealAccent, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Direct Chat with Admin', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                            Text(
                              'Request #${req.id} • ${req.mobileNumber}',
                              style: TextStyle(color: Colors.grey[400], fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.teal.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.teal.withOpacity(0.4)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.swap_horiz_rounded, color: Colors.tealAccent, size: 12),
                            SizedBox(width: 4),
                            Text('Direct Mode', style: TextStyle(color: Colors.tealAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),

                // Messages list
                Expanded(
                  child: state.chatMessages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.chat_bubble_outline, color: Colors.grey[700], size: 48),
                              const SizedBox(height: 12),
                              const Text('No messages yet.\nSend a message to start the conversation.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 13)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _chatScrollController,
                          padding: const EdgeInsets.all(16),
                          itemCount: state.chatMessages.length,
                          itemBuilder: (_, i) {
                            final msg = state.chatMessages[i];
                            final isMe = msg.sender == user?.id;
                            return Align(
                              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFF0D9488) : const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                                    bottomRight: Radius.circular(isMe ? 4 : 16),
                                  ),
                                  border: Border.all(color: isMe ? Colors.teal.withOpacity(0.3) : Colors.white.withOpacity(0.05)),
                                ),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      isMe ? 'You (TSP)' : 'Admin',
                                      style: TextStyle(
                                        color: isMe ? Colors.teal.shade100 : Colors.grey[400],
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(msg.message, style: const TextStyle(color: Colors.white, fontSize: 13.5)),
                                    const SizedBox(height: 4),
                                    Text(
                                      DateFormat('hh:mm a').format(msg.timestamp),
                                      style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 9),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // Input bar
                Container(
                  padding: EdgeInsets.only(
                    left: 16, right: 16, top: 10,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 12,
                  ),
                  color: const Color(0xFF1E293B),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _chatController,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                          maxLines: null,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) async {
                            final text = _chatController.text.trim();
                            if (text.isEmpty) return;
                            setState(() => _isSendingChat = true);
                            await state.sendChatMessage(text, req.id, receiverId: adminId);
                            _chatController.clear();
                            setState(() => _isSendingChat = false);
                            _scrollChatToBottom();
                          },
                          decoration: InputDecoration(
                            hintText: 'Message to Admin...',
                            hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _isSendingChat ? null : () async {
                          final text = _chatController.text.trim();
                          if (text.isEmpty) return;
                          setState(() => _isSendingChat = true);
                          await state.sendChatMessage(text, req.id, receiverId: adminId);
                          _chatController.clear();
                          setState(() => _isSendingChat = false);
                          _scrollChatToBottom();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [Color(0xFF0D9488), Color(0xFF0F766E)],
                            ),
                          ),
                          child: _isSendingChat
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)))
                              : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final user = state.currentUser;

    if (user == null) {
      return const LoginScreen();
    }

    final stats = state.tspStats;
    final tspName = stats['tsp_name'] ?? user.tspProviderDetails?.name ?? 'TSP Provider';

    // Get requests filtered by user's TSP Provider ID if we are using dummyUser
    final tspId = user.tspProviderId;
    final assignedRequests = state.requests
        .where((r) => (r.status == RequestStatus.FORWARDED || r.status == RequestStatus.PROCESSING) && (tspId == null || r.tspId == tspId))
        .toList();
    final respondedRequests = state.requests
        .where((r) => (r.status == RequestStatus.TSP_RESPONDED || r.status == RequestStatus.COMPLETED) && (tspId == null || r.tspId == tspId))
        .toList();

    final assignedCount = stats['assigned_requests'] ?? 0;
    final respondedCount = stats['responded_requests'] ?? 0;
    final completedCount = stats['completed_requests'] ?? 0;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(Icons.cell_tower, color: Color(0xFF6366F1)),
              const SizedBox(width: 10),
              Text(
                "TSP Portal: $tspName",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => state.refresh(),
              tooltip: "Refresh Data",
            ),
            IconButton(
              icon: const Icon(Icons.logout),
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
                    MaterialPageRoute(builder: (context) => const LoginScreen()),
                  );
                }
              },
              tooltip: "Log Out",
            ),
            const SizedBox(width: 10),
          ],
          bottom: const TabBar(
            indicatorColor: Color(0xFFEC4899),
            labelColor: Color(0xFFEC4899),
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(icon: Icon(Icons.assignment_late_outlined), text: "Assigned Requests"),
              Tab(icon: Icon(Icons.assignment_turned_in_outlined), text: "Response History"),
            ],
          ),
        ),
        body: Column(
          children: [
            // Stats panel at top
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  _buildMiniStatCard("Assigned", assignedCount.toString(), Colors.purple.shade600),
                  const SizedBox(width: 12),
                  _buildMiniStatCard("Responded", respondedCount.toString(), Colors.orange.shade700),
                  const SizedBox(width: 12),
                  _buildMiniStatCard("Completed", completedCount.toString(), Colors.green.shade600),
                ],
              ),
            ),

            // Tab view contents
            Expanded(
              child: TabBarView(
                children: [
                  _buildAssignedList(context, state, assignedRequests),
                  _buildResponseHistoryList(context, respondedRequests),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniStatCard(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.04)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 4),
            Row(
              children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
                const SizedBox(width: 6),
                Text(
                  value,
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _buildAssignedList(BuildContext context, AppState state, List<RequestModel> list) {
    if (list.isEmpty) {
      return const Center(child: Text("No new requests assigned to your TSP.", style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final req = list[index];
        final isForwarded = req.status == RequestStatus.FORWARDED;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              req.mobileNumber,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: isForwarded 
                                    ? Colors.purple.shade900.withOpacity(0.2) 
                                    : Colors.blue.shade900.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isForwarded 
                                      ? Colors.purpleAccent.withOpacity(0.3) 
                                      : Colors.blueAccent.withOpacity(0.3),
                                ),
                              ),
                              child: Text(
                                isForwarded ? "Pending Review" : "Under Review",
                                style: TextStyle(
                                  color: isForwarded ? Colors.purpleAccent : Colors.blueAccent, 
                                  fontSize: 9, 
                                  fontWeight: FontWeight.bold
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "Remarks: ${req.remarks.isNotEmpty ? req.remarks : (req.reason.isNotEmpty ? req.reason : 'None')}", 
                          style: TextStyle(color: Colors.grey[400], fontSize: 12)
                        ),
                        if (req.stationName.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.location_city_outlined, size: 12, color: Colors.grey[500]),
                              const SizedBox(width: 4),
                              Text(
                                "Station: ${req.stationName}",
                                style: TextStyle(color: Colors.grey[500], fontSize: 11),
                              ),
                            ],
                          ),
                        ],
                        if (req.crNo.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(Icons.confirmation_number_outlined, size: 12, color: Colors.grey[500]),
                              const SizedBox(width: 4),
                              Text(
                                "CR No: ${req.crNo}",
                                style: TextStyle(color: Colors.grey[500], fontSize: 11),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 2),
                        Text(
                          "Received: ${DateFormat('dd MMM, hh:mm a').format(req.updatedAt)}",
                          style: TextStyle(color: Colors.grey[500], fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (isForwarded)
                    ElevatedButton.icon(
                      onPressed: () async {
                        final success = await state.tspAccept(req.id);
                        if (success && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text("Request status updated to Under Review")),
                          );
                        }
                      },
                      icon: const Icon(Icons.rate_review_outlined, size: 16),
                      label: const Text("Review Request"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    )
                  else
                    ElevatedButton.icon(
                      onPressed: () => _showSubmitInfoDialog(context, state, req),
                      icon: const Icon(Icons.edit_note, size: 16),
                      label: const Text("Generate Response"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                ],
              ),

              // Direct Message Admin button (only in direct mode)
              if (state.allowDirectMessaging) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _openChatWithAdmin(context, state, req),
                    icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
                    label: const Text('Message Admin', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.tealAccent,
                      side: BorderSide(color: Colors.teal.withOpacity(0.5)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _showSubmitInfoDialog(BuildContext context, AppState state, RequestModel req) {
    final formKey = GlobalKey<FormState>();
    String selectedStatus = 'Active';
    final circleController = TextEditingController();
    final dateController = TextEditingController();
    final notesController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> selectDate() async {
              final DateTime? picked = await showDatePicker(
                context: context,
                initialDate: DateTime.now(),
                firstDate: DateTime(1990),
                lastDate: DateTime(2030),
                builder: (context, child) {
                  return Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: const ColorScheme.dark(
                        primary: Color(0xFFEC4899),
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
              if (picked != null) {
                setDialogState(() {
                  dateController.text = DateFormat('dd MMM yyyy').format(picked);
                });
              }
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF1E293B),
              title: Text("Submit Details: ${req.mobileNumber}", style: const TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        "Provide the official subscriber records, activation status, and registration info.",
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                      const SizedBox(height: 16),
                      
                      // Subscriber Status Dropdown
                      DropdownButtonFormField<String>(
                        value: selectedStatus,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: "Subscriber Status",
                          labelStyle: const TextStyle(color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        items: ['Active', 'Suspended', 'Deactivated', 'Unknown'].map((status) {
                          return DropdownMenuItem<String>(
                            value: status,
                            child: Text(status),
                          );
                        }).toList(),
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedStatus = val;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),

                      // Circle / State Input
                      TextFormField(
                        controller: circleController,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: "Circle / State",
                          labelStyle: const TextStyle(color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Please enter the telecom circle/state';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Activation Date Input
                      TextFormField(
                        controller: dateController,
                        readOnly: true,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: "Activation Date",
                          labelStyle: const TextStyle(color: Colors.grey),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.calendar_today, color: Color(0xFFEC4899), size: 18),
                            onPressed: selectDate,
                          ),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onTap: selectDate,
                        validator: (val) {
                          if (val == null || val.trim().isEmpty) {
                            return 'Please select an activation date';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      // Additional Notes Input
                      TextFormField(
                        controller: notesController,
                        maxLines: 3,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: "Additional Notes (Optional)",
                          labelStyle: const TextStyle(color: Colors.grey),
                          filled: true,
                          fillColor: const Color(0xFF0F172A),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
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
                    if (formKey.currentState!.validate()) {
                      final notesText = notesController.text.trim();
                      final formattedDetails = 
                          "Subscriber Status: $selectedStatus\n"
                          "Circle / State: ${circleController.text.trim()}\n"
                          "Activation Date: ${dateController.text.trim()}\n"
                          "Additional Notes: ${notesText.isNotEmpty ? notesText : 'N/A'}";

                      Navigator.pop(context);
                      final success = await state.tspRespond(req.id, formattedDetails, notes: notesText);
                      if (success && mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text("Response details submitted successfully.")),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  child: const Text("Submit Response"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildResponseHistoryList(BuildContext context, List<RequestModel> list) {
    if (list.isEmpty) {
      return const Center(child: Text("You haven't responded to any requests yet.", style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final req = list[index];
        final isCompleted = req.status == RequestStatus.COMPLETED;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
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
                  Text(
                    req.mobileNumber,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isCompleted ? Colors.green.shade900.withOpacity(0.4) : Colors.orange.shade900.withOpacity(0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isCompleted ? "Completed" : "Awaiting Review",
                      style: TextStyle(color: isCompleted ? Colors.greenAccent : Colors.orangeAccent, fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  )
                ],
              ),
              const SizedBox(height: 6),
              const Text("Details Provided:", style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold)),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(req.tspResponse?.details ?? '', style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
              const SizedBox(height: 4),
              Text(
                "Submitted: ${DateFormat('dd MMM, hh:mm a').format(req.tspResponse?.timestamp ?? req.updatedAt)}",
                style: TextStyle(color: Colors.grey[500], fontSize: 10),
              ),
            ],
          ),
        );
      },
    );
  }
}
