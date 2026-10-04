import 'package:http/browser_client.dart';

BrowserClient createClient() => BrowserClient()..withCredentials = true;
