class TSPProvider {
  final int id;
  final String name;
  final String code;
  final String contactEmail;
  final String mobileNumber;     // Outbound: admin sends requests TO this number
  final String inboundNumber;    // Inbound: TSP sends SMS response TO this number
  final String smsTemplate;      // Predefined SMS template format (e.g. Loc <Number>)
  final bool isDefault;
  final bool isActive;

  TSPProvider({
    required this.id,
    required this.name,
    required this.code,
    required this.contactEmail,
    required this.mobileNumber,
    this.inboundNumber = '',
    this.smsTemplate = '',
    required this.isDefault,
    required this.isActive,
  });

  factory TSPProvider.fromJson(Map<String, dynamic> json) {
    return TSPProvider(
      id: json['id'],
      name: json['name'] ?? '',
      code: json['code'] ?? '',
      contactEmail: json['contact_email'] ?? '',
      mobileNumber: json['mobile_number'] ?? '',
      inboundNumber: json['inbound_number'] ?? '',
      smsTemplate: json['sms_template'] ?? '',
      isDefault: json['is_default'] ?? false,
      isActive: json['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'contact_email': contactEmail,
      'mobile_number': mobileNumber,
      'inbound_number': inboundNumber,
      'sms_template': smsTemplate,
      'is_default': isDefault,
      'is_active': isActive,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TSPProvider &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
