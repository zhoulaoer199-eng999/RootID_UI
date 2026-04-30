import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/chat_message.dart';
import 'storage_keys.dart';

/// 本地 SQLite：消息与联系人。所有读写带 [ownerId]（当前设备 Identity），便于 2.0 多账号扩展。
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper instance = DatabaseHelper._();

  static const String _dbName = 'rootid_v1.db';
  static const int _dbVersion = 1;

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  Database? _db;

  final StreamController<void> _contactsChanged =
      StreamController<void>.broadcast();

  /// 联系人或会话摘要变更（HomePage 订阅刷新列表，避免轮询）。
  Stream<void> get onContactsChanged => _contactsChanged.stream;

  void notifyContactsChanged() {
    if (!_contactsChanged.isClosed) {
      _contactsChanged.add(null);
    }
  }

  Future<Database> _open() async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    final path = p.join(dir, _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_id TEXT NOT NULL,
  chat_with TEXT NOT NULL,
  from_id TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  is_me INTEGER NOT NULL
);
''');
        await db.execute(
            'CREATE INDEX idx_messages_owner_chat ON messages(owner_id, chat_with);');
        await db.execute('''
CREATE TABLE contacts (
  identity_id TEXT NOT NULL,
  owner_id TEXT NOT NULL,
  nickname TEXT,
  avatar TEXT,
  last_message TEXT,
  last_time INTEGER NOT NULL,
  PRIMARY KEY (owner_id, identity_id)
);
''');
        await db.execute(
            'CREATE INDEX idx_contacts_owner_time ON contacts(owner_id, last_time);');
      },
    );
    return _db!;
  }

  Future<String?> readOwnerIdFromSecureStorage() async {
    return _storage.read(key: kRootIdIdentityStorageKey);
  }

  /// 插入一条消息，返回 SQLite rowid。
  Future<int> insertMessage({
    required String ownerId,
    required String chatWith,
    required String fromId,
    required String content,
    required int isMe,
    int? timestampMs,
  }) async {
    final db = await _open();
    final ts = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
    return db.insert('messages', {
      'owner_id': ownerId,
      'chat_with': chatWith,
      'from_id': fromId,
      'content': content,
      'timestamp': ts,
      'is_me': isMe,
    });
  }

  Future<List<ChatMessage>> getMessagesByChatId({
    required String ownerId,
    required String chatWith,
  }) async {
    final db = await _open();
    final rows = await db.query(
      'messages',
      where: 'owner_id = ? AND chat_with = ?',
      whereArgs: [ownerId, chatWith],
      orderBy: 'timestamp ASC, id ASC',
    );
    return rows.map((r) => _rowToChatMessage(r, ownerId: ownerId)).toList();
  }

  ChatMessage _rowToChatMessage(Map<String, Object?> r,
      {required String ownerId}) {
    final id = r['id'] as int;
    final fromId = r['from_id'] as String;
    final chatWith = r['chat_with'] as String;
    final content = r['content'] as String;
    final ts = r['timestamp'] as int;
    final isMe = (r['is_me'] as int) == 1;
    return ChatMessage(
      id: 'db_$id',
      senderId: fromId,
      receiverId: isMe ? chatWith : ownerId,
      content: content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts),
    );
  }

  /// 写入或更新联系人摘要（发/收消息后调用）。
  Future<void> upsertContact({
    required String ownerId,
    required String identityId,
    String? nickname,
    String? avatar,
    required String lastMessage,
    required int lastTimeMs,
  }) async {
    final db = await _open();
    await db.insert(
      'contacts',
      {
        'owner_id': ownerId,
        'identity_id': identityId,
        'nickname': nickname,
        'avatar': avatar,
        'last_message': lastMessage,
        'last_time': lastTimeMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 手动关注：写入 contacts（无消息也可展示），并通知列表刷新。
  Future<void> followContactByIdentityId({
    required String ownerId,
    required String identityId,
  }) async {
    if (identityId == ownerId) return;
    final ts = DateTime.now().millisecondsSinceEpoch;
    await upsertContact(
      ownerId: ownerId,
      identityId: identityId,
      lastMessage: '',
      lastTimeMs: ts,
    );
    notifyContactsChanged();
  }

  /// 按最后活跃时间倒序，供 Home 会话列表。
  Future<List<Map<String, Object?>>> getContactsDescending({
    required String ownerId,
  }) async {
    final db = await _open();
    return db.query(
      'contacts',
      where: 'owner_id = ?',
      whereArgs: [ownerId],
      orderBy: 'last_time DESC',
    );
  }

  /// 根据 insert 返回的 rowid 构造 [ChatMessage]（避免再查库）。
  ChatMessage chatMessageFromInsertRow({
    required int rowId,
    required String ownerId,
    required String chatWith,
    required String fromId,
    required String content,
    required DateTime createdAt,
    required bool isMe,
  }) {
    return ChatMessage(
      id: 'db_$rowId',
      senderId: fromId,
      receiverId: isMe ? chatWith : ownerId,
      content: content,
      createdAt: createdAt,
    );
  }

  static int? tryParseDbRowId(String messageId) {
    if (!messageId.startsWith('db_')) return null;
    return int.tryParse(messageId.substring(3));
  }

  Future<void> deleteMessageByLocalId({
    required String ownerId,
    required int localRowId,
  }) async {
    final db = await _open();
    await db.delete(
      'messages',
      where: 'owner_id = ? AND id = ?',
      whereArgs: [ownerId, localRowId],
    );
  }

  Future<void> deleteMessagesByLocalIds({
    required String ownerId,
    required Iterable<int> localRowIds,
  }) async {
    final ids = localRowIds.toList();
    if (ids.isEmpty) return;
    final db = await _open();
    final placeholders = List.filled(ids.length, '?').join(',');
    await db.delete(
      'messages',
      where: 'owner_id = ? AND id IN ($placeholders)',
      whereArgs: [ownerId, ...ids],
    );
  }

  Future<void> closeForTests() async {
    await _db?.close();
    _db = null;
  }
}
