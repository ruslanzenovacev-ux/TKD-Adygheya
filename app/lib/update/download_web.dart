import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

const bool canDownloadFiles = true;

void downloadText(String filename, String content, String mimeType) {
  final bytes = utf8.encode(content);
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.appendChild(a);
  a.click();
  a.remove();
  web.URL.revokeObjectURL(url);
}
