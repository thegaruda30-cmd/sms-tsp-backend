import 'dart:convert';
import 'dart:io';
import '../lib/models/request.dart';

void main() {
  try {
    final file = File('../backend/requests_dump.json');
    final String content = file.readAsStringSync();
    final List data = jsonDecode(content);
    print('Total requests in file: ${data.length}');
    int successCount = 0;
    for (int i = 0; i < data.length; i++) {
      final json = data[i];
      try {
        RequestModel.fromJson(json);
        successCount++;
      } catch (e, stack) {
        print('Error at index $i (ID: ${json['id']}): $e');
        print(stack);
      }
    }
    print('Parsing result: $successCount / ${data.length} succeeded.');
  } catch (e) {
    print('Failed to read or decode file: $e');
  }
}
