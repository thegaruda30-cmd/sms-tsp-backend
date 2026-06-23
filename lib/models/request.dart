import 'request_status.dart';
import 'tsp_provider.dart';
import 'user.dart';
import 'tsp_response.dart';

class StatusLog {
  final int id;
  final String status;
  final String changedByName;
  final String changedByRole;
  final String remarks;
  final DateTime timestamp;

  StatusLog({
    required this.id,
    required this.status,
    required this.changedByName,
    required this.changedByRole,
    required this.remarks,
    required this.timestamp,
  });

  factory StatusLog.fromJson(Map<String, dynamic> json) {
    return StatusLog(
      id: json['id'],
      status: json['status'],
      changedByName: json['changed_by_name'] ?? 'System',
      changedByRole: json['changed_by_role'] ?? '',
      remarks: json['remarks'] ?? '',
      timestamp: DateTime.parse(json['timestamp']).toLocal(),
    );
  }
}

class RequestModel {
  final String crNo;
  final String location;
  final String stationName;
  final int id;
  final String mobileNumber;
  final int tspId;
  final TSPProvider? tspDetails;
  final String reason;
  final RequestStatus status;
  final int officerId;
  final User? officerDetails;
  final String officerName;
  final String remarks;
  final String adminRemarks;
  final bool isAutoApproved;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? forwardedAt;
  final String response;
  final DateTime? responseDate;
  final String adminStatus;
  final List<StatusLog> statusLogs;
  final TSPResponseModel? tspResponse;
  final String subject;
  final String message;
  final String ticketId;
  final List<SMSLogModel> smsLogs;

  RequestModel({
    required this.crNo,
    required this.location,
    this.stationName = '',
    required this.id,
    required this.mobileNumber,
    required this.tspId,
    this.tspDetails,
    required this.reason,
    required this.status,
    required this.officerId,
    this.officerDetails,
    required this.officerName,
    required this.remarks,
    required this.adminRemarks,
    required this.isAutoApproved,
    required this.createdAt,
    required this.updatedAt,
    this.forwardedAt,
    required this.response,
    this.responseDate,
    required this.adminStatus,
    required this.statusLogs,
    this.tspResponse,
    required this.subject,
    required this.message,
    required this.ticketId,
    required this.smsLogs,
  });

  factory RequestModel.fromJson(Map<String, dynamic> json) {
    var logsList = json['status_logs'] as List? ?? [];
    List<StatusLog> logs = logsList.map((l) => StatusLog.fromJson(l)).toList();

    var smsLogsList = json['sms_logs'] as List? ?? [];
    List<SMSLogModel> smsLogsParsed = smsLogsList.map((s) => SMSLogModel.fromJson(s)).toList();

    return RequestModel(
      crNo: json['cr_no'] ?? '',
      location: json['location'] ?? '',
      stationName: json['station_name'] ?? '',
      id: json['id'],
      mobileNumber: json['mobile_number'] ?? '',
      tspId: json['tsp'],
      tspDetails: json['tsp_details'] != null ? TSPProvider.fromJson(json['tsp_details']) : null,
      reason: json['reason'] ?? '',
      status: RequestStatus.fromString(json['status']),
      officerId: json['officer'],
      officerDetails: json['officer_details'] != null ? User.fromJson(json['officer_details']) : null,
      officerName: json['officer_name'] ?? '',
      remarks: json['remarks'] ?? '',
      adminRemarks: json['admin_remarks'] ?? '',
      isAutoApproved: json['is_auto_approved'] ?? false,
      createdAt: DateTime.parse(json['created_at']).toLocal(),
      updatedAt: DateTime.parse(json['updated_at']).toLocal(),
      forwardedAt: json['forwarded_at'] != null ? DateTime.parse(json['forwarded_at']).toLocal() : null,
      response: json['response'] ?? '',
      responseDate: json['response_date'] != null ? DateTime.parse(json['response_date']).toLocal() : null,
      adminStatus: json['admin_status'] ?? 'Pending',
      statusLogs: logs,
      tspResponse: json['tsp_response'] != null ? TSPResponseModel.fromJson(json['tsp_response']) : null,
      subject: json['subject'] ?? '',
      message: json['message'] ?? '',
      ticketId: json['ticket_id'] ?? '',
      smsLogs: smsLogsParsed,
    );
  }
}

class SMSLogModel {
  final int id;
  final int requestId;
  final String direction;
  final String operator;
  final String tspNumber;
  final String message;
  final DateTime timestamp;

  SMSLogModel({
    required this.id,
    required this.requestId,
    required this.direction,
    required this.operator,
    required this.tspNumber,
    required this.message,
    required this.timestamp,
  });

  factory SMSLogModel.fromJson(Map<String, dynamic> json) {
    return SMSLogModel(
      id: json['id'] ?? 0,
      requestId: json['request'] ?? 0,
      direction: json['direction'] ?? '',
      operator: json['operator'] ?? '',
      tspNumber: json['tsp_number'] ?? '',
      message: json['message'] ?? '',
      timestamp: DateTime.parse(json['timestamp']).toLocal(),
    );
  }
}
