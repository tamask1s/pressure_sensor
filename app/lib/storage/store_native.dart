import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../core/model.dart';
import 'store_api.dart';

Future<Store> openStore(String account, {String? file}) async {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(account)) {
    throw const FormatException('Hibás fiókazonosító');
  }
  if (Platform.isWindows) {
    sqfliteFfiInit();
  }
  final factory = Platform.isWindows
      ? databaseFactoryFfi
      : mobile.databaseFactory;
  final location =
      file ??
      path.join(
        (await getApplicationSupportDirectory()).path,
        'measurements-$account.sqlite',
      );
  final db = await factory.openDatabase(
    location,
    options: OpenDatabaseOptions(
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=FULL');
        await db.execute('PRAGMA foreign_keys=ON');
      },
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE meta(key TEXT PRIMARY KEY, data TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE sessions(id TEXT PRIMARY KEY, start TEXT NOT NULL, end TEXT, started INTEGER NOT NULL DEFAULT 0, completed INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE records(kind TEXT NOT NULL,id TEXT NOT NULL,session_id TEXT NOT NULL REFERENCES sessions(id),at INTEGER NOT NULL,device TEXT,data TEXT NOT NULL,ready INTEGER NOT NULL,synced INTEGER NOT NULL DEFAULT 0,batch TEXT,PRIMARY KEY(kind,id))',
        );
        await db.execute(
          'CREATE INDEX records_session ON records(session_id,kind,at,id)',
        );
        await db.execute(
          'CREATE INDEX records_pending ON records(session_id,synced,ready,batch)',
        );
        await db.execute(
          'CREATE TABLE outbox(id TEXT PRIMARY KEY,session_id TEXT NOT NULL UNIQUE REFERENCES sessions(id),data TEXT NOT NULL)',
        );
      },
    ),
  );
  return SqlStore(db);
}

class SqlStore implements Store {
  final Database db;
  SqlStore(this.db);
  @override
  Future<Json?> meta(String key) async {
    final r = await db.query('meta', where: 'key=?', whereArgs: [key]);
    return r.isEmpty ? null : object(jsonDecode(r.first['data'] as String));
  }

  @override
  Future<void> putMeta(String key, Json value) async {
    await db.insert('meta', {
      'key': key,
      'data': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> startSession(String id, Json start) async {
    await db.insert('sessions', {'id': id, 'start': jsonEncode(start)});
  }

  @override
  Future<List<Json>> sessions() async =>
      (await db.query('sessions', orderBy: 'rowid DESC'))
          .map(
            (r) => {
              'id': r['id'],
              'start': object(jsonDecode(r['start'] as String)),
              'end': r['end'] == null
                  ? null
                  : object(jsonDecode(r['end'] as String)),
              'started': r['started'] == 1,
              'completed': r['completed'] == 1,
            },
          )
          .toList();
  @override
  Future<void> finishSession(String id, Json end) async {
    await db.update(
      'sessions',
      {'end': jsonEncode(end)},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> writeRecords(String session, List<Json> records) async {
    await db.transaction((tx) async {
      for (final r in records) {
        final d = object(r['data']), encoded = jsonEncode(d);
        final old = await tx.query(
          'records',
          columns: ['session_id', 'data'],
          where: 'kind=? AND id=?',
          whereArgs: [r['kind'], r['id']],
          limit: 1,
        );
        if (old.isNotEmpty) {
          if (old.first['data'] != encoded ||
              old.first['session_id'] != session) {
            throw const FormatException('Eltérő ismételt mérési rekord');
          }
          continue;
        }
        await tx.insert('records', {
          'kind': r['kind'],
          'id': r['id'],
          'session_id': session,
          'at': d['captured_at'] == null ? 0 : milliseconds(d['captured_at']),
          'device': d['device_id'],
          'data': encoded,
          'ready': r['ready'] == true ? 1 : 0,
        });
      }
    });
  }

  @override
  Future<List<Json>> pendingSamples(String session, {int limit = 1000}) async =>
      (await db.query(
            'records',
            where: 'session_id=? AND kind=? AND ready=0',
            whereArgs: [session, 'samples'],
            orderBy: 'at,id',
            limit: limit,
          ))
          .map(
            (r) => {
              'id': r['id'],
              'data': object(jsonDecode(r['data'] as String)),
            },
          )
          .toList();
  @override
  Future<void> finalizeSamples(List<Json> samples) async {
    await db.transaction((tx) async {
      for (final s in samples) {
        await tx.update(
          'records',
          {'data': jsonEncode(s['data']), 'ready': 1},
          where: 'kind=? AND id=? AND ready=0 AND batch IS NULL',
          whereArgs: ['samples', s['id']],
        );
      }
    });
  }

  @override
  Stream<List<Json>> records(String session, String kind) async* {
    int? at;
    String? id;
    while (true) {
      final rows = await db.query(
        'records',
        where:
            'session_id=? AND kind=?${at == null ? '' : ' AND (at,id)>(?,?)'}',
        whereArgs: [
          session,
          kind,
          if (at != null) ...[at, id],
        ],
        orderBy: 'at,id',
        limit: 1000,
      );
      if (rows.isEmpty) break;
      yield rows.map((r) => object(jsonDecode(r['data'] as String))).toList();
      at = rows.last['at'] as int;
      id = rows.last['id'] as String;
    }
  }

  @override
  Future<Json?> nextBatch(String session) => db.transaction((tx) async {
    final existing = await tx.query(
      'outbox',
      where: 'session_id=?',
      whereArgs: [session],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return object(jsonDecode(existing.first['data'] as String));
    }
    final selected = <String, Map<String, Object?>>{};
    Future<void> include(Map<String, Object?> row) async {
      final key = '${row['kind']}/${row['id']}';
      if (selected.containsKey(key) || row['synced'] == 1) return;
      final data = object(jsonDecode(row['data'] as String));
      final dependencies = <String, String>{};
      if (row['kind'] == 'samples') {
        dependencies[data['time_segment_id'] as String] = 'time_segments';
        if (data['location'] != null) {
          for (final field in ['fix_before_id', 'fix_after_id']) {
            dependencies[data['location'][field] as String] = 'gps_fixes';
          }
        }
      }
      if (row['kind'] == 'gps_fixes') {
        dependencies[data['segment_id'] as String] = 'time_segments';
      }
      for (final dep in dependencies.entries) {
        final rows = await tx.query(
          'records',
          where: 'session_id=? AND kind=? AND id=?',
          whereArgs: [session, dep.value, dep.key],
          limit: 1,
        );
        if (rows.isEmpty) {
          throw const FormatException('Hiányzó idő- vagy GPS-hivatkozás');
        }
        await include(rows.first);
      }
      selected[key] = row;
    }

    final rows = await tx.query(
      'records',
      where: 'session_id=? AND synced=0 AND ready=1 AND batch IS NULL',
      whereArgs: [session],
      orderBy: 'at,id',
      limit: 100,
    );
    if (rows.isEmpty) return null;
    for (final row in rows) {
      final before = Map<String, Map<String, Object?>>.of(selected);
      await include(row);
      int count(String kind) =>
          selected.values.where((r) => r['kind'] == kind).length;
      if (count('gps_fixes') > 100 || count('time_segments') > 20) {
        selected
          ..clear()
          ..addAll(before);
        break;
      }
    }
    if (selected.isEmpty) {
      throw const FormatException(
        'A rekord függőségei túllépik a kötegkorlátot',
      );
    }
    final id = ids.v4(),
        data = <String, dynamic>{
          'batch_id': id,
          'time_segments': <Json>[],
          'gps_fixes': <Json>[],
          'samples': <Json>[],
        };
    for (final r in selected.values) {
      (data[r['kind']] as List).add(object(jsonDecode(r['data'] as String)));
    }
    final encoded = jsonEncode(data);
    if (utf8.encode(encoded).length > 512 * 1024) {
      throw const FormatException('Túl nagy feltöltési köteg');
    }
    await tx.insert('outbox', {
      'id': id,
      'session_id': session,
      'data': encoded,
    });
    for (final r in selected.values) {
      await tx.update(
        'records',
        {'batch': id},
        where: 'kind=? AND id=?',
        whereArgs: [r['kind'], r['id']],
      );
    }
    return data;
  });
  @override
  Future<void> acknowledge(String batchId) async {
    await db.transaction((tx) async {
      await tx.update(
        'records',
        {'synced': 1, 'batch': null},
        where: 'batch=?',
        whereArgs: [batchId],
      );
      await tx.delete('outbox', where: 'id=?', whereArgs: [batchId]);
    });
  }

  @override
  Future<void> markStarted(String id) async {
    await db.update('sessions', {'started': 1}, where: 'id=?', whereArgs: [id]);
  }

  @override
  Future<void> markComplete(String id) async {
    await db.update(
      'sessions',
      {'completed': 1},
      where: 'id=?',
      whereArgs: [id],
    );
  }

  @override
  Future<int> pendingCount() async =>
      (await db.rawQuery(
            "SELECT COUNT(*) AS n FROM records WHERE kind='samples' AND synced=0",
          )).first['n']
          as int;
  @override
  Future<Map<String, int>> counts(String session) async => {
    for (final r in await db.rawQuery(
      "SELECT device,COUNT(*) AS n FROM records WHERE session_id=? AND kind='samples' GROUP BY device",
      [session],
    ))
      r['device'] as String: r['n'] as int,
  };
  @override
  Future<void> close() => db.close();
}
