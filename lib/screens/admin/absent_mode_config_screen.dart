import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../../models/user.dart';

class AbsentModeConfigScreen extends StatefulWidget {
  const AbsentModeConfigScreen({super.key});

  @override
  State<AbsentModeConfigScreen> createState() => _AbsentModeConfigScreenState();
}

class _AbsentModeConfigScreenState extends State<AbsentModeConfigScreen> {
  int? _selectedOfficerId;

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppState>(context);
    final isAbsentMode = state.adminAbsentMode;
    final absentModeType = state.adminAbsentModeType;

    // Filter officers
    final allowedOfficers = state.fieldOfficers
        .where((o) => o.directForwardAllowed == true)
        .toList();
    final addableOfficers = state.fieldOfficers
        .where((o) => o.directForwardAllowed == false)
        .toList();

    // Reset dropdown selection if the previously selected officer is no longer in addable list
    if (_selectedOfficerId != null &&
        !addableOfficers.any((o) => o.id == _selectedOfficerId)) {
      _selectedOfficerId = null;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Absent Mode Configuration',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'Manage request routing permissions when offline',
              style: TextStyle(
                color: Colors.grey,
                fontSize: 11,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Switch Card
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isAbsentMode
                      ? Colors.amberAccent.withOpacity(0.3)
                      : Colors.blueAccent.withOpacity(0.15),
                  width: 1.5,
                ),
              ),
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (isAbsentMode ? Colors.amberAccent : Colors.blueAccent).withOpacity(0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isAbsentMode ? Icons.person_off_rounded : Icons.person_rounded,
                      color: isAbsentMode ? Colors.amberAccent : Colors.blueAccent,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Direct Send: Admin Absent Mode',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          isAbsentMode
                              ? 'Enabled: Requests bypass Admin review.'
                              : 'Disabled: All requests require Admin review.',
                          style: TextStyle(
                            color: isAbsentMode ? Colors.amberAccent[100] : Colors.blueAccent[100],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: isAbsentMode,
                    onChanged: (val) async {
                      await state.toggleAdminAbsentMode(val);
                    },
                    activeColor: Colors.amberAccent,
                    activeTrackColor: Colors.amberAccent.withOpacity(0.3),
                    inactiveThumbColor: Colors.blueAccent,
                    inactiveTrackColor: Colors.blueAccent.withOpacity(0.25),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Mode Selector Heading
            const Text(
              'ROUTING POLICY',
              style: TextStyle(
                color: Color(0xFF6366F1),
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 12),

            // Option 1: Allow All
            _buildOptionCard(
              title: 'Allow All Officers',
              subtitle: 'Any officer can submit requests directly to TSPs through the gateway while Admin is absent.',
              icon: Icons.people_alt_rounded,
              isSelected: absentModeType == 'all',
              onTap: () => state.updateAdminAbsentModeType('all'),
            ),
            const SizedBox(height: 14),

            // Option 2: Allow Specific
            _buildOptionCard(
              title: 'Allow Specific Officers Only',
              subtitle: 'Only designated officers will bypass review. All other requests remain queued for Admin approval.',
              icon: Icons.admin_panel_settings_rounded,
              isSelected: absentModeType == 'specific',
              onTap: () => state.updateAdminAbsentModeType('specific'),
            ),

            if (absentModeType == 'specific') ...[
              const SizedBox(height: 28),
              // Specific Officers Selection Section
              const Text(
                'ALLOWED OFFICERS LIST',
                style: TextStyle(
                  color: Color(0xFF6366F1),
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 12),

              // Add Officer Selector Card
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Add Officer to Allowed List',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _selectedOfficerId,
                            hint: const Text(
                              'Select an officer',
                              style: TextStyle(color: Colors.grey, fontSize: 13),
                            ),
                            dropdownColor: const Color(0xFF0F172A),
                            decoration: InputDecoration(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.08)),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: const BorderSide(color: Color(0xFF6366F1), width: 1.5),
                              ),
                            ),
                            items: addableOfficers.map((User officer) {
                              return DropdownMenuItem<int>(
                                value: officer.id,
                                child: Text(
                                  officer.fullName,
                                  style: const TextStyle(color: Colors.white, fontSize: 13),
                                ),
                              );
                            }).toList(),
                            onChanged: (int? newVal) {
                              setState(() {
                                _selectedOfficerId = newVal;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: _selectedOfficerId == null
                              ? null
                              : () async {
                                  if (_selectedOfficerId != null) {
                                    final officerId = _selectedOfficerId!;
                                    setState(() {
                                      _selectedOfficerId = null;
                                    });
                                    await state.toggleOfficerPermission(
                                        officerId, true);
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Officer added to direct forwarding.'),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                    }
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF6366F1),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.add_rounded, color: Colors.white, size: 18),
                              SizedBox(width: 6),
                              Text('Save', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              // Allowed Officers List View
              if (allowedOfficers.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withOpacity(0.5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.04)),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.people_outline_rounded, color: Colors.grey, size: 36),
                      SizedBox(height: 10),
                      Text(
                        'No specific officers configured.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Requests will require Admin review by default.',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: allowedOfficers.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final officer = allowedOfficers[index];
                    return Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: const Color(0xFF6366F1).withOpacity(0.12),
                            child: const Icon(Icons.person_outline_rounded, color: Color(0xFF6366F1)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  officer.fullName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13.5,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  officer.email.isNotEmpty ? officer.email : 'No email added',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Colors.redAccent.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                            ),
                            onPressed: () async {
                              await state.toggleOfficerPermission(officer.id, false);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('${officer.fullName} removed from direct forwarding.'),
                                    backgroundColor: Colors.redAccent,
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOptionCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected ? const Color(0xFF6366F1) : Colors.white.withOpacity(0.06),
          width: isSelected ? 1.8 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (isSelected ? const Color(0xFF6366F1) : Colors.grey[800])!.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    icon,
                    color: isSelected ? const Color(0xFF6366F1) : Colors.grey,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: isSelected ? Colors.white : Colors.grey[300],
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 11.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                Radio<bool>(
                  value: true,
                  groupValue: isSelected,
                  activeColor: const Color(0xFF6366F1),
                  onChanged: (val) => onTap(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
