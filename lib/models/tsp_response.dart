class TSPResponseModel {
  final int id;
  final int? requestId;
  final String details;
  final int? submittedBy;
  final String submittedByName;
  final DateTime timestamp;
  
  final String mobileNumber;
  final String tspProvider;
  final String subscriberStatus;
  final String circle;
  final DateTime? activationDate;
  final String additionalNotes;
  final DateTime? responseDate;
  final String status;
  
  final int? createdBy;
  final String createdByName;
  final DateTime createdAt;

  TSPResponseModel({
    required this.id,
    this.requestId,
    this.details = '',
    this.submittedBy,
    this.submittedByName = '',
    required this.timestamp,
    required this.mobileNumber,
    required this.tspProvider,
    required this.subscriberStatus,
    required this.circle,
    this.activationDate,
    required this.additionalNotes,
    this.responseDate,
    required this.status,
    this.createdBy,
    this.createdByName = '',
    required this.createdAt,
  });

  factory TSPResponseModel.fromJson(Map<String, dynamic> json) {
    return TSPResponseModel(
      id: json['id'],
      requestId: json['request'],
      details: json['details'] ?? '',
      submittedBy: json['submitted_by'],
      submittedByName: json['submitted_by_name'] ?? '',
      timestamp: DateTime.parse(json['timestamp'] ?? json['created_at'] ?? DateTime.now().toIso8601String()).toLocal(),
      mobileNumber: json['mobile_number'] ?? '',
      tspProvider: json['tsp_provider'] ?? '',
      subscriberStatus: json['subscriber_status'] ?? '',
      circle: json['circle'] ?? '',
      activationDate: json['activation_date'] != null ? DateTime.parse(json['activation_date']).toLocal() : null,
      additionalNotes: json['additional_notes'] ?? '',
      responseDate: json['response_date'] != null ? DateTime.parse(json['response_date']).toLocal() : null,
      status: json['status'] ?? 'Pending',
      createdBy: json['created_by'],
      createdByName: json['created_by_name'] ?? '',
      createdAt: DateTime.parse(json['created_at'] ?? DateTime.now().toIso8601String()).toLocal(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'request': requestId,
      'details': details,
      'submitted_by': submittedBy,
      'timestamp': timestamp.toIso8601String(),
      'mobile_number': mobileNumber,
      'tsp_provider': tspProvider,
      'subscriber_status': subscriberStatus,
      'circle': circle,
      'activation_date': activationDate != null ? "${activationDate!.year.toString().padLeft(4, '0')}-${activationDate!.month.toString().padLeft(2, '0')}-${activationDate!.day.toString().padLeft(2, '0')}" : null,
      'additional_notes': additionalNotes,
      'response_date': responseDate?.toIso8601String(),
      'status': status,
      'created_by': createdBy,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
