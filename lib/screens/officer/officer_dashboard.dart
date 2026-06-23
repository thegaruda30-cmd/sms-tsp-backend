import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../providers/app_state.dart';
import '../../models/user.dart';
import '../../models/request.dart';
import '../../models/request_status.dart';
import '../../models/user_role.dart';
import '../../models/tsp_provider.dart';
import '../../services/api_service.dart';
import '../../services/download_helper_stub.dart'
    if (dart.library.html) '../../services/download_helper_web.dart'
    if (dart.library.io) '../../services/download_helper_nonweb.dart';
import '../login_screen.dart';

class OfficerDashboard extends StatefulWidget {
  const OfficerDashboard({super.key});

  @override
  State<OfficerDashboard> createState() => _OfficerDashboardState();
}

class _OfficerDashboardState extends State<OfficerDashboard> {
  final _formKey = GlobalKey<FormState>();
  final _mobileController = TextEditingController();
  final _remarksController = TextEditingController();
  final _stationNameController = TextEditingController();
  final _crNoController = TextEditingController();
  final _searchController = TextEditingController();
  TSPProvider? _selectedTspProvider;
  String _selectedTspFilter = 'All';
  String _searchQuery = '';
  String _sortBy = 'Newest First';

  @override
  void dispose() {
    _mobileController.dispose();
    _remarksController.dispose();
    _stationNameController.dispose();
    _crNoController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Widget? _buildLimitStatusBanner(AppState state, User user) {
    if (user.role != UserRole.OFFICER) return null;

    final officerRequests = state.requests.where((r) => r.officerId == user.id).toList();
    final now = DateTime.now();
    final todayRequestsCount = officerRequests.where((r) {
      return r.createdAt.year == now.year &&
             r.createdAt.month == now.month &&
             r.createdAt.day == now.day;
    }).length;

    int activeLimit = 5;
    bool isUnlimited = false;
    bool isBypassActive = false;

    if (user.bypassDailyLimit) {
      if (user.bypassExpiryDate != null) {
        if (user.isBypassActive) {
          activeLimit = 5 + user.extraRequestsLimit;
          isBypassActive = true;
        }
      } else {
        isUnlimited = true;
        isBypassActive = true;
      }
    }

    if (isBypassActive && isUnlimited) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF065F46),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF047857)),
        ),
        child: const Row(
          children: [
            Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                "Daily limit bypassed. Unlimited requests allowed.",
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ],
        ),
      );
    }

    if (!isUnlimited && todayRequestsCount >= activeLimit) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF7F1D1D),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF991B1B)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    user.bypassRequested
                        ? "Daily limit ($activeLimit) reached. Bypass request pending admin approval."
                        : "Daily limit ($activeLimit) reached. Request a limit bypass to send more.",
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (!user.bypassRequested) ...[
              const SizedBox(height: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                ),
                onPressed: () async {
                  final success = await state.requestLimitBypass();
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          success
                              ? "Bypass request sent to admin successfully!"
                              : "Failed to send bypass request.",
                        ),
                        backgroundColor: success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                      ),
                    );
                  }
                },
                child: const Text("Request Limit Bypass", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Expanded(
            child: Text(
              "Daily limit usage:",
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isUnlimited ? "$todayRequestsCount / Unlimited requests" : "$todayRequestsCount / $activeLimit requests",
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Future<void> _submitRequest(AppState state) async {
    if (!_formKey.currentState!.validate() || _selectedTspProvider == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please fill all details and select a TSP")),
      );
      return;
    }

    final user = state.currentUser;
    if (user != null) {
      final officerRequests = state.requests.where((r) => r.officerId == user.id).toList();
      final now = DateTime.now();
      final todayRequestsCount = officerRequests.where((r) {
        return r.createdAt.year == now.year &&
               r.createdAt.month == now.month &&
               r.createdAt.day == now.day;
      }).length;

      int activeLimit = 5;
      bool isUnlimited = false;
      if (user.bypassDailyLimit) {
        if (user.bypassExpiryDate != null) {
          if (user.isBypassActive) {
            activeLimit = 5 + user.extraRequestsLimit;
          }
        } else {
          isUnlimited = true;
        }
      }

      if (!isUnlimited && todayRequestsCount >= activeLimit) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 22),
                SizedBox(width: 8),
                Text("Limit Exceeded", style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              user.bypassRequested
                  ? "You have reached your daily limit of $activeLimit lookup requests. Your request for a limit bypass is pending admin approval."
                  : "You have reached your daily limit of $activeLimit lookup requests. Please contact the Admin or request a limit bypass to send more requests.",
              style: const TextStyle(color: Colors.grey, fontSize: 12.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Close", style: TextStyle(color: Colors.grey)),
              ),
              if (!user.bypassRequested)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () async {
                    Navigator.pop(context);
                    final success = await state.requestLimitBypass();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            success
                                ? "Bypass request sent to admin successfully!"
                                : "Failed to send bypass request.",
                          ),
                          backgroundColor: success ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                        ),
                      );
                    }
                  },
                  child: const Text("Request Bypass"),
                ),
            ],
          ),
        );
        return;
      }
    }

    final int tspId = _selectedTspProvider!.id;

    final success = await state.createRequest(
      _mobileController.text.trim(),
      tspId,
      remarks: _remarksController.text.trim(),
      stationName: _stationNameController.text.trim(),
      crNo: _crNoController.text.trim(),
      subject: '',
      message: '',
    );

    if (success) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Request submitted successfully and logged in admin chat!")),
      );
      _mobileController.clear();
      _remarksController.clear();
      _stationNameController.clear();
      _crNoController.clear();
      setState(() {
        _selectedTspProvider = null;
      });
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Failed to submit request. Please try again.")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final user = state.currentUser;

    if (user == null) {
      return const LoginScreen();
    }

    // Filter requests created by this officer that are completed or closed
    final officerRequests = state.requests
        .where((r) => r.officerId == user.id &&
            (r.status == RequestStatus.COMPLETED || r.status == RequestStatus.CLOSED))
        .toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(Icons.location_searching, color: Color(0xFFEC4899)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "Officer Portal: ${user.fullName}",
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, letterSpacing: 0.5),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => state.refresh(),
              tooltip: "Refresh",
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
              Tab(icon: Icon(Icons.send_rounded), text: "Send Data"),
              Tab(icon: Icon(Icons.download_done_rounded), text: "Received Data"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildSendDataForm(state),
            _buildReceivedDataList(state, officerRequests),
          ],
        ),
      ),
    );
  }

  Widget _buildSendDataForm(AppState state) {
    final user = state.currentUser;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.04)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 15,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        "Submit Lookup Information",
                        style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        state.allowDirectForwarding
                            ? "Fill in the details below to send data directly to TSP."
                            : "Fill in the details below. Your request will go to Admin for approval.",
                        style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      ),
                      const SizedBox(height: 14),
                      if (user != null) _buildLimitStatusBanner(state, user) ?? const SizedBox(),





                      // Mobile Number Input
                      TextFormField(
                        controller: _mobileController,
                        keyboardType: TextInputType.phone,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Mobile Number",
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.phone_outlined, color: Color(0xFFEC4899)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A).withOpacity(0.5),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter mobile number';
                          }
                          if (value.length < 10) {
                            return 'Please enter a valid phone number';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 20),

                      // Station Name Input
                      TextFormField(
                        controller: _stationNameController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "Station Name",
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          hintText: "e.g. Kotwali Police Station",
                          hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                          prefixIcon: const Icon(Icons.location_city_outlined, color: Color(0xFFEC4899)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A).withOpacity(0.5),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // CR Number Input
                      TextFormField(
                        controller: _crNoController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: "CR Number",
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          hintText: "e.g. CR-2024-00123",
                          hintStyle: TextStyle(color: Colors.grey[600], fontSize: 12),
                          prefixIcon: const Icon(Icons.confirmation_number_outlined, color: Color(0xFFEC4899)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A).withOpacity(0.5),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // TSP Selection Dropdown (hardcoded options)
                      DropdownButtonFormField<TSPProvider>(
                        value: state.tsps.any((t) => t.id == _selectedTspProvider?.id)
                            ? state.tsps.firstWhere((t) => t.id == _selectedTspProvider!.id)
                            : null,
                        isExpanded: true,
                        dropdownColor: const Color(0xFF1E293B),
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey),
                        decoration: InputDecoration(
                          labelText: "Operator",
                          labelStyle: TextStyle(color: Colors.grey[400]),
                          prefixIcon: const Icon(Icons.cell_tower, color: Color(0xFFEC4899)),
                          filled: true,
                          fillColor: const Color(0xFF0F172A).withOpacity(0.5),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: Colors.grey.withOpacity(0.3)),
                          ),
                        ),
                        items: state.tsps.map((tsp) {
                          return DropdownMenuItem<TSPProvider>(
                            value: tsp,
                            child: Text(
                              tsp.name,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                            ),
                          );
                        }).toList(),
                        onChanged: (value) {
                          setState(() {
                            _selectedTspProvider = value;
                          });
                        },
                        validator: (value) => value == null ? 'Please select a TSP' : null,
                      ),
                      const SizedBox(height: 20),



                      // Submit Button
                      Container(
                        height: 50,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          gradient: const LinearGradient(
                            colors: [Color(0xFFEC4899), Color(0xFFBE185D)],
                          ),
                        ),
                        child: ElevatedButton(
                          onPressed: state.isLoading ? null : () => _submitRequest(state),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: Colors.white,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: state.isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)),
                                )
                               : Text(
                                  state.allowDirectForwarding
                                      ? "Send Directly to TSP"
                                      : "Send to Admin for Approval",
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReceivedDataList(AppState state, List<RequestModel> list) {
    List<RequestModel> filteredList = List.from(list);

    // Apply TSP filter
    if (_selectedTspFilter != 'All') {
      filteredList = filteredList.where((r) {
        final cleanFilter = _selectedTspFilter.toLowerCase();
        final cleanTsp = (r.tspDetails?.name ?? '').toLowerCase();
        if (cleanFilter.contains('vodafone') || cleanFilter == 'vi') {
          return cleanTsp.contains('vodafone') || cleanTsp.contains('vi');
        }
        return cleanTsp.contains(cleanFilter);
      }).toList();
    }

    // Apply Search Query filter
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      filteredList = filteredList.where((r) {
        return r.mobileNumber.contains(query) ||
               r.ticketId.toLowerCase().contains(query) ||
               r.stationName.toLowerCase().contains(query) ||
               r.crNo.toLowerCase().contains(query) ||
               r.remarks.toLowerCase().contains(query);
      }).toList();
    }

    // Apply Sorting (Newest First vs Oldest First)
    if (_sortBy == 'Newest First') {
      filteredList.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } else {
      filteredList.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final currentUser = state.currentUser;

    return Column(
      children: [


        // Dropdown Filters Row
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
          child: Row(
            children: [
              // TSP Filter
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.filter_alt_outlined, color: Colors.grey, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedTspFilter,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey, size: 18),
                            isExpanded: true,
                            items: ["All", "Airtel", "Jio", "BSNL", "Vi"].map((tsp) {
                              return DropdownMenuItem<String>(
                                value: tsp,
                                child: Text("TSP: $tsp"),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                  setState(() {
                                    _selectedTspFilter = value;
                                  });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Sort dropdown
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.sort_rounded, color: Colors.grey, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _sortBy,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.grey, size: 18),
                            isExpanded: true,
                            items: ["Newest First", "Oldest First"].map((item) {
                              return DropdownMenuItem<String>(
                                value: item,
                                child: Text(item),
                              );
                            }).toList(),
                            onChanged: (value) {
                              if (value != null) {
                                  setState(() {
                                    _sortBy = value;
                                  });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        
        // List of Requests
        Expanded(
          child: filteredList.isEmpty
              ? Center(
                  child: Text(
                    _selectedTspFilter == 'All'
                        ? "No data received. Submit details to get started."
                        : "No received data found for $_selectedTspFilter.",
                    style: const TextStyle(color: Colors.grey, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  itemCount: filteredList.length,
                  itemBuilder: (context, index) {
                    final req = filteredList[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.04)),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        child: Theme(
                          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                          child: ExpansionTile(
                            leading: _buildStatusIndicator(req.status),
                            title: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (req.ticketId.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      req.ticketId,
                                      style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                Text(
                                  req.mobileNumber,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                ),
                                _buildTspBadge(req.tspDetails?.name ?? 'Jio'),
                              ],
                            ),
                            subtitle: Text(
                              "Subject: ${req.subject.isNotEmpty ? req.subject : (req.remarks.isNotEmpty ? req.remarks : 'None')}",
                              style: TextStyle(color: Colors.grey[400], fontSize: 12),
                            ),
                            childrenPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            expandedAlignment: Alignment.topLeft,
                            children: [
                              Divider(color: Colors.white.withOpacity(0.05)),
                              const SizedBox(height: 8),
                              if (req.ticketId.isNotEmpty)
                                _buildDetailsRow("Ticket ID", req.ticketId),
                              _buildDetailsRow("TSP", req.tspDetails?.name ?? 'Jio'),
                              if (req.subject.isNotEmpty)
                                _buildDetailsRow("Subject", req.subject),
                              if (req.message.isNotEmpty)
                                _buildDetailsRow("Message", req.message),
                              if (req.stationName.isNotEmpty)
                                _buildDetailsRow("Station", req.stationName),
                              if (req.crNo.isNotEmpty)
                                _buildDetailsRow("CR Number", req.crNo),
                              if (req.remarks.isNotEmpty)
                                _buildDetailsRow("Remarks", req.remarks),
                              _buildDetailsRow("Date", DateFormat('dd MMM yyyy, hh:mm a').format(req.createdAt)),
                              if (req.adminRemarks.isNotEmpty)
                                _buildDetailsRow("Admin Remarks", req.adminRemarks, valueColor: Colors.orangeAccent),
                              if (req.response.isNotEmpty || req.tspResponse != null) ...[
                                const SizedBox(height: 8),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF0F172A),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        "TSP Response Received:",
                                        style: TextStyle(color: Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        req.response.isNotEmpty ? req.response : (req.tspResponse?.details ?? ''),
                                        style: const TextStyle(color: Colors.white, fontSize: 12.5),
                                      ),
                                      if (req.responseDate != null) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          "Response Date: ${DateFormat('dd MMM yyyy, hh:mm a').format(req.responseDate!)}",
                                          style: TextStyle(color: Colors.grey[500], fontSize: 10),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (req.status == RequestStatus.COMPLETED) ...[
                                    TextButton.icon(
                                      onPressed: () async {
                                        final success = await state.closeRequest(req.id);
                                        if (success && mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text("Request marked as Closed")),
                                          );
                                        }
                                      },
                                      icon: const Icon(Icons.check_circle_outline, size: 16),
                                      label: const Text("Close Request"),
                                      style: TextButton.styleFrom(
                                        foregroundColor: Colors.greenAccent,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                  TextButton.icon(
                                    onPressed: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) => RequestChatScreen(request: req),
                                        ),
                                      );
                                    },
                                    icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16),
                                    label: const Text("Chat with Admin"),
                                    style: TextButton.styleFrom(
                                      foregroundColor: const Color(0xFFEC4899),
                                    ),
                                  ),
                                ],
                              )
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
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

  Widget _buildDetailsRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              "$label:",
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: valueColor ?? Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator(RequestStatus status) {
    Color bg;
    Color fg;
    String label;

    switch (status) {
      case RequestStatus.PENDING:
        bg = Colors.amber.shade900.withOpacity(0.2);
        fg = Colors.amberAccent;
        label = "Pending";
        break;
      case RequestStatus.APPROVED:
        bg = Colors.blue.shade900.withOpacity(0.2);
        fg = Colors.blueAccent;
        label = "Approved";
        break;
      case RequestStatus.PROCESSING:
        bg = Colors.blue.shade900.withOpacity(0.2);
        fg = Colors.blueAccent;
        label = "Processing";
        break;
      case RequestStatus.REJECTED:
        bg = Colors.red.shade900.withOpacity(0.2);
        fg = Colors.redAccent;
        label = "Rejected";
        break;
      case RequestStatus.FORWARDED:
        bg = Colors.purple.shade900.withOpacity(0.2);
        fg = Colors.purpleAccent;
        label = "Forwarded";
        break;
      case RequestStatus.TSP_RESPONDED:
        bg = Colors.cyan.shade900.withOpacity(0.2);
        fg = Colors.cyanAccent;
        label = "Responded";
        break;
      case RequestStatus.COMPLETED:
        bg = Colors.green.shade900.withOpacity(0.2);
        fg = Colors.greenAccent;
        label = "Completed";
        break;
      case RequestStatus.CLOSED:
        bg = Colors.grey.shade900.withOpacity(0.2);
        fg = Colors.grey;
        label = "Closed";
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: fg.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// ─── Interactive Request Chat Screen ──────────────────────────────────────────
class RequestChatScreen extends StatefulWidget {
  final RequestModel request;
  const RequestChatScreen({super.key, required this.request});

  @override
  State<RequestChatScreen> createState() => _RequestChatScreenState();
}

class _RequestChatScreenState extends State<RequestChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadMessages();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _loadMessages() async {
    final state = Provider.of<AppState>(context, listen: false);
    await state.loadChatMessages(widget.request.id);
    _scrollToBottom();
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

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isSending = true;
    });

    final state = Provider.of<AppState>(context, listen: false);
    final success = await state.sendChatMessage(
      text,
      widget.request.id,
      receiverId: 1, // Default receiver is admin
    );

    if (success) {
      _messageController.clear();
      _scrollToBottom();
    }

    setState(() {
      _isSending = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final user = state.currentUser ?? User(
      id: 2,
      username: 'officer_ranjeet',
      email: 'officer@smstsp.com',
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

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Chat: Req #${widget.request.id} (${widget.request.mobileNumber})",
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
            Text(
              "Remarks: ${widget.request.remarks.length > 40 ? widget.request.remarks.substring(0, 40) + '...' : widget.request.remarks}",
              style: TextStyle(fontSize: 10, color: Colors.grey[400]),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _loadMessages,
            tooltip: "Refresh Chat",
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Chat logs
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: state.chatMessages.length,
              itemBuilder: (context, index) {
                final msg = state.chatMessages[index];
                final isMe = msg.sender == user.id;
                
                return _buildChatBubble(msg, isMe);
              },
            ),
          ),

          // Chat input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border(top: BorderSide(color: Colors.white.withOpacity(0.04))),
            ),
            child: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: "Type a message...",
                        hintStyle: TextStyle(color: Colors.grey[500], fontSize: 13),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: _isSending ? null : _sendMessage,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Color(0xFFEC4899), Color(0xFFBE185D)],
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
          ),
        ],
      ),
    );
  }

  Widget _buildChatBubble(msg, bool isMe) {
    // Check if it's the custom initial request card
    final isRequestCard = msg.message.contains("🚨 **New Lookup Request** 🚨");
    
    if (isRequestCard) {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 16),
          padding: const EdgeInsets.all(16),
          constraints: const BoxConstraints(maxWidth: 340),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFEC4899).withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.location_searching, color: Color(0xFFEC4899), size: 18),
                  SizedBox(width: 8),
                  Text(
                    "INITIAL SYSTEM TRANSMISSION",
                    style: TextStyle(color: Color(0xFFEC4899), fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.5),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                msg.message.replaceAll("🚨 **New Lookup Request** 🚨\n\n", ""),
                style: const TextStyle(color: Colors.white, fontSize: 12.5, height: 1.4),
              ),
              const SizedBox(height: 10),
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

    // Standard Chat Bubbles
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFEC4899).withOpacity(0.15) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isMe ? 16 : 4),
            bottomRight: Radius.circular(isMe ? 4 : 16),
          ),
          border: Border.all(
            color: isMe ? const Color(0xFFEC4899).withOpacity(0.2) : Colors.white.withOpacity(0.04),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe)
              Text(
                "${msg.senderName} (${msg.senderRole})",
                style: const TextStyle(color: Color(0xFFEC4899), fontSize: 10, fontWeight: FontWeight.bold),
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
}
