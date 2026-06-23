class TspSetting {
  final String? id;
  final String tspName;
  final String forwardNumber;
  final String smsTemplate;
  final bool isActive;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  TspSetting({
    this.id,
    required this.tspName,
    required this.forwardNumber,
    required this.smsTemplate,
    required this.isActive,
    this.createdAt,
    this.updatedAt,
  });

  factory TspSetting.fromJson(Map<String, dynamic> json) {
    return TspSetting(
      id: json['id'],
      tspName: json['tsp_name'] ?? '',
      forwardNumber: json['forward_number'] ?? '',
      smsTemplate: json['sms_template'] ?? '',
      isActive: json['is_active'] ?? true,
      createdAt: json['created_at'] != null ? DateTime.parse(json['created_at']) : null,
      updatedAt: json['updated_at'] != null ? DateTime.parse(json['updated_at']) : null,
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> data = {
      'tsp_name': tspName,
      'forward_number': forwardNumber,
      'sms_template': smsTemplate,
      'is_active': isActive,
    };
    if (id != null) {
      data['id'] = id;
    }
    return data;
  }
}
