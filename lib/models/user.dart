import 'user_role.dart';
import 'tsp_provider.dart';

class User {
  final int id;
  final String username;
  final String email;
  final UserRole role;
  final int? tspProviderId;
  final TSPProvider? tspProviderDetails;
  final bool directForwardAllowed;
  final bool bypassDailyLimit;
  final bool bypassRequested;
  final int extraRequestsLimit;
  final DateTime? bypassExpiryDate;
  final bool isBypassActive;
  final String firstName;
  final String lastName;

  User({
    required this.id,
    required this.username,
    required this.email,
    required this.role,
    this.tspProviderId,
    this.tspProviderDetails,
    required this.directForwardAllowed,
    required this.bypassDailyLimit,
    required this.bypassRequested,
    required this.extraRequestsLimit,
    this.bypassExpiryDate,
    required this.isBypassActive,
    required this.firstName,
    required this.lastName,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'],
      username: json['username'],
      email: json['email'] ?? '',
      role: UserRole.fromString(json['role']),
      tspProviderId: json['tsp_provider'],
      tspProviderDetails: json['tsp_provider_details'] != null
          ? TSPProvider.fromJson(json['tsp_provider_details'])
          : null,
      directForwardAllowed: json['direct_forward_allowed'] ?? false,
      bypassDailyLimit: json['bypass_daily_limit'] ?? false,
      bypassRequested: json['bypass_requested'] ?? false,
      extraRequestsLimit: json['extra_requests_limit'] ?? 0,
      bypassExpiryDate: json['bypass_expiry_date'] != null ? DateTime.parse(json['bypass_expiry_date']).toLocal() : null,
      isBypassActive: json['is_bypass_active'] ?? false,
      firstName: json['first_name'] ?? '',
      lastName: json['last_name'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'username': username,
      'email': email,
      'role': role.toShortString(),
      'tsp_provider': tspProviderId,
      'tsp_provider_details': tspProviderDetails?.toJson(),
      'direct_forward_allowed': directForwardAllowed,
      'bypass_daily_limit': bypassDailyLimit,
      'bypass_requested': bypassRequested,
      'extra_requests_limit': extraRequestsLimit,
      'bypass_expiry_date': bypassExpiryDate?.toIso8601String(),
      'is_bypass_active': isBypassActive,
      'first_name': firstName,
      'last_name': lastName,
    };
  }

  String get fullName {
    if (firstName.isEmpty && lastName.isEmpty) {
      return username;
    }
    return '$firstName $lastName'.trim();
  }
}
