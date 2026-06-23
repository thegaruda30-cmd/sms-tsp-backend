import 'dart:html' as html;
import 'package:http/http.dart' as http;

Future<void> downloadFile(String url, String fileName, Map<String, String> headers) async {
  final response = await http.get(Uri.parse(url), headers: headers);
  if (response.statusCode == 200) {
    final blob = html.Blob([response.bodyBytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final blobUrl = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: blobUrl)
      ..setAttribute("download", fileName)
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(blobUrl);
  } else {
    throw Exception('Failed to download file: ${response.statusCode}');
  }
}
