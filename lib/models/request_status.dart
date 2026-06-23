import 'package:flutter/material.dart';
 
enum RequestStatus {
  PENDING,
  APPROVED,
  PROCESSING,
  REJECTED,
  FORWARDED,
  TSP_RESPONDED,
  COMPLETED,
  CLOSED;
 
  static RequestStatus fromString(String status) {
    switch (status.toUpperCase()) {
      case 'PENDING':
        return RequestStatus.PENDING;
      case 'APPROVED':
        return RequestStatus.APPROVED;
      case 'PROCESSING':
        return RequestStatus.PROCESSING;
      case 'REJECTED':
        return RequestStatus.REJECTED;
      case 'FORWARDED':
        return RequestStatus.FORWARDED;
      case 'TSP_RESPONDED':
        return RequestStatus.TSP_RESPONDED;
      case 'COMPLETED':
        return RequestStatus.COMPLETED;
      case 'CLOSED':
        return RequestStatus.CLOSED;
      default:
        return RequestStatus.PENDING;
    }
  }
 
  String toShortString() {
    return this.toString().split('.').last;
  }
 
  String get displayName {
    switch (this) {
      case RequestStatus.PENDING:
        return 'Pending Admin Approval';
      case RequestStatus.APPROVED:
        return 'Approved';
      case RequestStatus.PROCESSING:
        return 'Processing';
      case RequestStatus.REJECTED:
        return 'Rejected';
      case RequestStatus.FORWARDED:
        return 'Forwarded to TSP';
      case RequestStatus.TSP_RESPONDED:
        return 'TSP Response Received';
      case RequestStatus.COMPLETED:
        return 'Forwarded to Officer';
      case RequestStatus.CLOSED:
        return 'Closed';
    }
  }
 
  Color get color {
    switch (this) {
      case RequestStatus.PENDING:
        return Colors.amber.shade700;
      case RequestStatus.APPROVED:
        return Colors.blue.shade600;
      case RequestStatus.PROCESSING:
        return Colors.blue.shade800;
      case RequestStatus.REJECTED:
        return Colors.red.shade600;
      case RequestStatus.FORWARDED:
        return Colors.purple.shade600;
      case RequestStatus.TSP_RESPONDED:
        return Colors.orange.shade700;
      case RequestStatus.COMPLETED:
        return Colors.green.shade600;
      case RequestStatus.CLOSED:
        return Colors.grey.shade600;
    }
  }
 
  String getDetailedStatus(String tspName) {
    switch (this) {
      case RequestStatus.PENDING:
        return 'Pending Admin Approval';
      case RequestStatus.APPROVED:
        return 'Approved';
      case RequestStatus.PROCESSING:
        return 'Under Review';
      case RequestStatus.REJECTED:
        return 'Rejected';
      case RequestStatus.FORWARDED:
        return 'Forwarded to $tspName';
      case RequestStatus.TSP_RESPONDED:
        return 'TSP Response Received';
      case RequestStatus.COMPLETED:
        return 'Forwarded to Officer';
      case RequestStatus.CLOSED:
        return 'Closed';
    }
  }
}
