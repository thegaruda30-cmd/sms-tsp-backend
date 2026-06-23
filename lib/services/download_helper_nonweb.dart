import 'dart:io';
import 'package:http/http.dart' as http;

Future<void> downloadFile(String url, String fileName, Map<String, String> headers) async {
  final response = await http.get(Uri.parse(url), headers: headers);
  if (response.statusCode == 200) {
    final file = File(fileName);
    await file.writeAsBytes(response.bodyBytes);
  } else {
    throw Exception('Failed to download file: ${response.statusCode}');
  }
}
