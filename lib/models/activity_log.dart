class ActivityLog {
  final int id;
  final String action;
  final String userName;
  final String userRole;
  final int? requestId;
  final String? mobileNumber;
  final String? details;
  final DateTime timestamp;

  ActivityLog({
    required this.id,
    required this.action,
    required this.userName,
    required this.userRole,
    this.requestId,
    this.mobileNumber,
    this.details,
    required this.timestamp,
  });

  factory ActivityLog.fromJson(Map<String, dynamic> json) {
    return ActivityLog(
      id: json['id'],
      action: json['action'] ?? '',
      userName: json['user_name'] ?? 'System',
      userRole: json['user_role'] ?? '',
      requestId: json['request'],
      mobileNumber: json['mobile_number'],
      details: json['details'],
      timestamp: DateTime.parse(json['timestamp']).toLocal(),
    );
  }
}
