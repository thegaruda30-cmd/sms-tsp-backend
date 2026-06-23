class ChatMessage {
  final int id;
  final int sender;
  final String senderName;
  final String senderRole;
  final int receiver;
  final String receiverName;
  final String receiverRole;
  final int? requestId;
  final String message;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.senderName,
    required this.senderRole,
    required this.receiver,
    required this.receiverName,
    required this.receiverRole,
    this.requestId,
    required this.message,
    required this.timestamp,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'],
      sender: json['sender'],
      senderName: json['sender_name'] ?? '',
      senderRole: json['sender_role'] ?? '',
      receiver: json['receiver'],
      receiverName: json['receiver_name'] ?? '',
      receiverRole: json['receiver_role'] ?? '',
      requestId: json['request'],
      message: json['message'] ?? '',
      timestamp: DateTime.parse(json['timestamp']).toLocal(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'sender': sender,
      'sender_name': senderName,
      'sender_role': senderRole,
      'receiver': receiver,
      'receiver_name': receiverName,
      'receiver_role': receiverRole,
      'request': requestId,
      'message': message,
      'timestamp': timestamp.toIso8601String(),
    };
  }
}
