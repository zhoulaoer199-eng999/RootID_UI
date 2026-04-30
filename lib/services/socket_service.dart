import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/chat_message.dart';
import 'database_helper.dart';
import 'socket_config.dart';
import 'storage_keys.dart';

/// 下行聊天事件：先落库再发出，[message] 与数据库一致。
class SocketIncomingChat {
  final String from;
  final String content;
  final ChatMessage message;

  SocketIncomingChat({
    required this.from,
    required this.content,
    required this.message,
  });
}

/// 全局 WebSocket 单例：登录绑定 Identity、chat 转发、心跳、断线重连。
class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  final StreamController<SocketIncomingChat> _incoming =
      StreamController<SocketIncomingChat>.broadcast();

  final StreamController<String> _connectionHints =
      StreamController<String>.broadcast();

  /// 订阅后，在 ChatPage 中过滤 `message.senderId == widget.receiverId`。
  Stream<SocketIncomingChat> get incomingChat => _incoming.stream;

  /// 连接异常时推送文案，供页面用 SnackBar 提示（已做节流）。
  Stream<String> get connectionHints => _connectionHints.stream;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeat;
  Timer? _reconnectTimer;

  Uri? _uri;
  String? _identityId;
  bool _wantConnect = false;

  DateTime? _lastConnectionHintAt;

  String? get identityId => _identityId;

  void _emitConnectionHint(String message) {
    final now = DateTime.now();
    if (_lastConnectionHintAt != null &&
        now.difference(_lastConnectionHintAt!) < const Duration(seconds: 12)) {
      return;
    }
    _lastConnectionHintAt = now;
    if (!_connectionHints.isClosed) {
      _connectionHints.add(message);
    }
  }

  /// 读取本地 Identity 并连接 [url]；默认使用 [kDefaultSocketUrl]（见 socket_config.dart）。
  Future<void> connect({String url = kDefaultSocketUrl}) async {
    _wantConnect = true;
    _uri = Uri.parse(url);
    _identityId = await _storage.read(key: kRootIdIdentityStorageKey);
    if (_identityId == null || _identityId!.isEmpty) {
      return;
    }
    await _connectNow();
  }

  Future<void> _connectNow() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final uri = _uri;
    final id = _identityId;
    if (!_wantConnect || uri == null || id == null || id.isEmpty) return;

    await _disposeChannel();

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _onSocketData,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );
      _sendJson({'type': 'login', 'id': id});
      _armHeartbeat();
    } catch (_) {
      _emitConnectionHint(kSocketConnectionFailureHint);
      _scheduleReconnect();
    }
  }

  void _onSocketData(dynamic data) {
    if (data is! String) return;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return;
      msg = decoded;
    } catch (_) {
      return;
    }
    if (msg['type'] == 'chat' &&
        msg['from'] != null &&
        msg['content'] != null) {
      unawaited(_persistAndEmitIncoming(
        from: msg['from'].toString(),
        content: msg['content'].toString(),
      ));
    }
  }

  Future<void> _persistAndEmitIncoming({
    required String from,
    required String content,
  }) async {
    final myId = _identityId;
    if (myId == null || myId.isEmpty) return;

    final text = content.trim();
    if (text.isEmpty) return;

    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;

    final rowId = await DatabaseHelper.instance.insertMessage(
      ownerId: myId,
      chatWith: from,
      fromId: from,
      content: text,
      isMe: 0,
      timestampMs: ts,
    );

    await DatabaseHelper.instance.upsertContact(
      ownerId: myId,
      identityId: from,
      lastMessage: text,
      lastTimeMs: ts,
    );

    DatabaseHelper.instance.notifyContactsChanged();

    final chatMsg = DatabaseHelper.instance.chatMessageFromInsertRow(
      rowId: rowId,
      ownerId: myId,
      chatWith: from,
      fromId: from,
      content: text,
      createdAt: now,
      isMe: false,
    );

    _incoming.add(SocketIncomingChat(
      from: from,
      content: text,
      message: chatMsg,
    ));
  }

  void _onSocketError(Object error, StackTrace stackTrace) {
    _emitConnectionHint(kSocketConnectionFailureHint);
    unawaited(_disposeChannel());
    _scheduleReconnect();
  }

  void _onSocketDone() {
    unawaited(_disposeChannel());
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_wantConnect) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      if (_wantConnect) {
        unawaited(_connectNow());
      }
    });
  }

  void _armHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
      _sendJson({'type': 'ping'});
    });
  }

  void _sendJson(Map<String, Object?> payload) {
    final ch = _channel;
    if (ch == null) return;
    try {
      ch.sink.add(jsonEncode(payload));
    } catch (_) {}
  }

  /// 先写入 [messages] 与 [contacts]，再发往服务端（I/O 在异步方法内，不阻塞 UI isolate）。
  Future<ChatMessage?> sendChat({
    required String toId,
    required String content,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return null;
    final myId = _identityId;
    if (myId == null || myId.isEmpty) return null;

    final now = DateTime.now();
    final ts = now.millisecondsSinceEpoch;

    final rowId = await DatabaseHelper.instance.insertMessage(
      ownerId: myId,
      chatWith: toId,
      fromId: myId,
      content: text,
      isMe: 1,
      timestampMs: ts,
    );

    await DatabaseHelper.instance.upsertContact(
      ownerId: myId,
      identityId: toId,
      lastMessage: text,
      lastTimeMs: ts,
    );

    DatabaseHelper.instance.notifyContactsChanged();

    final chatMsg = DatabaseHelper.instance.chatMessageFromInsertRow(
      rowId: rowId,
      ownerId: myId,
      chatWith: toId,
      fromId: myId,
      content: text,
      createdAt: now,
      isMe: true,
    );

    _sendJson({'type': 'chat', 'to': toId, 'content': text});
    return chatMsg;
  }

  Future<void> _disposeChannel() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    final ch = _channel;
    _channel = null;
    if (ch != null) {
      try {
        await ch.sink.close(ws_status.normalClosure);
      } catch (_) {}
    }
  }

  /// 退出应用或显式登出时可调用（当前 1.0 默认保持长连接）。
  Future<void> disconnect() async {
    _wantConnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _disposeChannel();
  }
}
