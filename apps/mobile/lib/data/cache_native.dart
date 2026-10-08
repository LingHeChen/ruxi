import 'dart:convert';

import 'package:sqflite/sqflite.dart';

class RoomCache {
  Database? _db;
  Future<void> _tail = Future.value();
  Future<Database> get db async => _db ??= await openDatabase(
    '${await getDatabasesPath()}/ruxi_views.db',
    version: 1,
    onCreate: (db, _) => db.execute(
      'CREATE TABLE cache (account TEXT PRIMARY KEY, value TEXT NOT NULL)',
    ),
  );
  Future<Map<String, dynamic>?> read(String account) async {
    final rows = await (await db).query(
      'cache',
      where: 'account = ?',
      whereArgs: [account],
    );
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(jsonDecode(rows.first['value'] as String));
  }

  Future<void> write(String account, Map<String, dynamic> value) {
    final encoded = jsonEncode(value);
    _tail = _tail.catchError((_) {}).then((_) async {
      await (await db).insert('cache', {
        'account': account,
        'value': encoded,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return _tail;
  }

  Future<void> clear(String account) async {
    await _tail;
    await (await db).delete(
      'cache',
      where: 'account = ?',
      whereArgs: [account],
    );
  }
}
