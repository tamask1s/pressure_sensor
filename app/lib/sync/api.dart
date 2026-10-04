import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/model.dart';
import '../platform/http_client.dart';
import '../platform/vault.dart';

class ApiError extends UserError {
  final int status;
  final String code;
  const ApiError(this.status, this.code, super.message);
}

class Api {
  final http.Client client;
  final String vaultNamespace;
  String base;
  Json? account;
  String? _access, _refresh, _csrf;
  Future<void>? _refreshing;
  Api(this.base, {http.Client? client, this.vaultNamespace = ''})
    : client = client ?? createClient();
  bool get configured => base.isNotEmpty;
  String get vaultKey => '${vaultNamespace}auth:$base';
  Future<void> restore() async {
    if (!configured) return;
    if (kIsWeb) {
      try {
        account = object((await call('GET', '/auth/session'))['account']);
      } on ApiError catch (e) {
        if (e.status != 401) rethrow;
      }
      return;
    }
    final saved = await readVault(vaultKey);
    if (saved == null) return;
    account = object(saved['account']);
    _refresh = saved['refresh_token'] as String?;
    // A cached account can collect offline; credentials are revalidated at sync.
  }

  Future<void> login(String email, String password) async {
    final r = await call(
      'POST',
      '/auth/login',
      body: {
        'email': email.trim(),
        'password': password,
        'client_kind': kIsWeb ? 'web' : 'native',
      },
      authenticated: false,
    );
    account = object(r['account']);
    if (kIsWeb) {
      await call('GET', '/auth/session');
    } else {
      _access = r['access_token'] as String;
      _refresh = r['refresh_token'] as String;
      await _save();
    }
  }

  Future<void> _save() =>
      writeVault(vaultKey, {'account': account, 'refresh_token': _refresh});
  Future<void> refresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  Future<void> _doRefresh() async {
    if (_refresh == null) {
      throw const ApiError(
        401,
        'login_required',
        'A feltöltéshez jelentkezz be újra. A helyi adatok megmaradnak.',
      );
    }
    final r = await call(
      'POST',
      '/auth/refresh',
      body: {'refresh_token': _refresh},
      authenticated: false,
    );
    if (r['account'] != null && r['account']['id'] != account?['id']) {
      throw const ApiError(
        401,
        'account_mismatch',
        'A fiókazonosító megváltozott. Jelentkezz be újra.',
      );
    }
    _access = r['access_token'] as String;
    _refresh = r['refresh_token'] as String;
    await _save();
  }

  Future<void> logout() async {
    try {
      await call('POST', '/auth/logout');
    } finally {
      await writeVault(vaultKey, null);
      _access = _refresh = _csrf = null;
      account = null;
    }
  }

  Uri uri(String path, [Map<String, String>? query]) {
    final u = Uri.parse('${base.replaceAll(RegExp(r'/+$'), '')}$path');
    final resolved = kIsWeb ? Uri.base.resolveUri(u) : u;
    if (resolved.userInfo.isNotEmpty || resolved.fragment.isNotEmpty) {
      throw const UserError(
        'A szolgáltatás címe nem tartalmazhat jelszót vagy hivatkozástöredéket.',
      );
    }
    if (resolved.scheme != 'https' &&
        !(const bool.fromEnvironment('ALLOW_LOCAL_HTTP') &&
            resolved.scheme == 'http' &&
            ['localhost', '127.0.0.1', '10.0.2.2'].contains(resolved.host))) {
      throw const UserError('A szolgáltatás címe HTTPS-cím legyen.');
    }
    return resolved.replace(
      queryParameters: query?.isEmpty == true ? null : query,
    );
  }

  Future<Json> call(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool authenticated = true,
    bool retry = true,
  }) async {
    final response = await request(
      method,
      path,
      body: body,
      query: query,
      authenticated: authenticated,
      retry: retry,
    );
    return response.bodyBytes.isEmpty
        ? {}
        : object(jsonDecode(utf8.decode(response.bodyBytes)));
  }

  Future<http.Response> request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool authenticated = true,
    bool retry = true,
  }) async {
    if (!configured) {
      throw const UserError('Először add meg a szolgáltatás HTTPS-címét.');
    }
    if (authenticated && !kIsWeb && _access == null && _refresh != null) {
      await refresh();
    }
    final req = http.Request(method, uri(path, query))..followRedirects = false;
    req.headers['Accept'] = 'application/json';
    if (authenticated && _access != null) {
      req.headers['Authorization'] = 'Bearer $_access';
    }
    if (kIsWeb && _csrf != null && method != 'GET') {
      req.headers['X-CSRF-Token'] = _csrf!;
    }
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    ).timeout(const Duration(seconds: 30));
    if (res.statusCode == 401 &&
        authenticated &&
        retry &&
        !kIsWeb &&
        _refresh != null) {
      await refresh();
      return request(
        method,
        path,
        body: body,
        query: query,
        authenticated: true,
        retry: false,
      );
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Json error = {};
      try {
        error = object(jsonDecode(res.body))['error'] as Json? ?? {};
      } catch (_) {}
      final messages = {
        401:
            'A belépés lejárt. A helyi mérés folytatódik; jelentkezz be újra a feltöltéshez.',
        403: 'Erősítsd meg az e-mail-címedet.',
        409: 'Ütközés történt. Az adatokat megőriztük; frissítsd a listát.',
        429: 'Túl sok kérés. Próbáld meg később.',
      };
      throw ApiError(
        res.statusCode,
        error['code'] as String? ?? 'http_error',
        error['code'] == 'admin_required' || error['code'] == 'import_conflict'
            ? error['message'] as String
            : error['code'] == 'claim_unavailable'
            ? 'Az eszköz nem párosítható. Ellenőrizd a gyártói regisztrációját és hogy nem tartozik-e másik fiókhoz, majd nyisd újra a párosítási ablakot. Szimulátornál a devices.simulator.json fájlt előbb importálni kell a service-be.'
            : messages[res.statusCode] ??
                  error['message'] as String? ??
                  'A szolgáltatás hibát jelzett (${res.statusCode}).',
      );
    }
    if (kIsWeb && path == '/auth/session' && res.bodyBytes.isNotEmpty) {
      final session = object(jsonDecode(res.body));
      _csrf = session['csrf_token'] as String?;
      account = object(session['account']);
    }
    return res;
  }

  Future<List<Json>> list(String path, {Map<String, String>? query}) async {
    final result = <Json>[];
    String? cursor;
    do {
      final page = await call(
        'GET',
        path,
        query: {
          ...?query,
          'limit': '1000',
          if (cursor != null) 'cursor': cursor,
        },
      );
      result.addAll(objects(page['items']));
      final next = page['next_cursor'] as String?;
      if (next != null && next == cursor) {
        throw const FormatException('Ismétlődő lapozási kurzor');
      }
      cursor = next;
    } while (cursor != null);
    return result;
  }

  void close() => client.close();
}
