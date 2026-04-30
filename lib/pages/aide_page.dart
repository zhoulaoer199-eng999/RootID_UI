import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';
import '../models/chat_message.dart';
import '../services/database_helper.dart';
import '../services/socket_service.dart';
import '../services/storage_keys.dart';
import '../widgets/user_identity_card.dart';
import '../widgets/emoji_panel.dart';
import '../widgets/tools_drawer.dart';
import 'home_page.dart';
import 'tool_placeholder_page.dart';

const _kAideId = 'aide';
const _kMyUserId = 'me';

extension _MsgUI on ChatMessage {
  String get text => content;
  bool get isMe => senderId == _kMyUserId;
  DateTime get timestamp => createdAt;
}

enum _ComposerMode { text, voice, emoji, tools }
enum _MessageAction { reply, copy, forward, multiSelect, delete }

class AidePage extends StatefulWidget {
  const AidePage({super.key});

  @override
  State<AidePage> createState() => _AidePageState();
}

class _AidePageState extends State<AidePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static final RegExp _followIdPattern = RegExp(r'^[a-z0-9]{8}$');
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _localIdentityId;
  bool _isBound = false;
  bool _showUnboundBanner = true;
  bool _isVerifying = false;
  String _verifyingLabel = '';
  bool _hasBackedUpKey = false;
  bool _hasAnyFriendConversation = false;
  final TextEditingController _followSearchController = TextEditingController();

  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _translateMenuAnchorKey = GlobalKey();
  final GlobalKey _inputBarKey = GlobalKey();
  final GlobalKey _composerKey = GlobalKey();
  final GlobalKey _micAnchorKey = GlobalKey();

  _ComposerMode _composerMode = _ComposerMode.text;
  bool _composerExpanded = false;

  bool _composerMeasureScheduled = false;
  double? _composerHeight;
  bool _inputBarMeasureScheduled = false;
  double? _inputBarHeight;

  bool _isRecording = false;
  bool _isRecordingLocked = false;
  Duration _recordingDuration = Duration.zero;
  Timer? _recordingTimer;
  Offset? _recordStartGlobal;
  DateTime? _recordStartAt;

  double _lastKeyboardHeight = 320;
  bool _pendingKeyboardOpen = false;
  double _lastViewInsetBottom = 0;

  bool _inputHasFocus = false;

  String? _activeMessageMenuId;
  String? _replyToMessageId;
  String? _replyToMessageText;
  bool _multiSelectMode = false;
  final Set<String> _selectedMessageIds = <String>{};

  List<ChatMessage> _messages = [];

  StreamSubscription<String>? _socketHintSub;
  Timer? _bindingPollTimer;

  bool _suppressScrollCollapse = false;

  double? _dragStartX;
  double _dragCurrentX = 0;

  late AnimationController _waveController;
  late AnimationController _rippleController;
  late AnimationController _menuController;
  late AnimationController _ringFadeController;

  static const double _cancelDx = -78;
  static const double _lockDy = -78;
  static const int _minRecordMs = 900;

  bool get _emojiOpen => _composerMode == _ComposerMode.emoji;
  bool get _toolsOpen => _composerMode == _ComposerMode.tools;
  bool get _voiceOpen => _composerMode == _ComposerMode.voice;

  bool get _inputExpanded =>
      _inputHasFocus || _controller.text.trim().isNotEmpty;

  void _unfocusInput() => FocusScope.of(context).unfocus();

  void _scheduleMeasureComposer() {
    if (_composerMeasureScheduled) return;
    _composerMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerMeasureScheduled = false;
      final ctx = _composerKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if (_composerHeight != null && (h - _composerHeight!).abs() <= 1) return;
      if (!mounted) return;
      setState(() => _composerHeight = h);
    });
  }

  void _scheduleMeasureInputBar() {
    if (_inputBarMeasureScheduled) return;
    _inputBarMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _inputBarMeasureScheduled = false;
      final ctx = _inputBarKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final h = box.size.height;
      if (_inputBarHeight != null && (h - _inputBarHeight!).abs() <= 0.5) return;
      if (!mounted) return;
      setState(() => _inputBarHeight = h);
    });
  }

  double _desiredExpandedHeight(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    if (kb > _lastKeyboardHeight + 1) {
      _lastKeyboardHeight = kb;
    }
    return _lastKeyboardHeight;
  }

  void _collapseComposer() {
    if (_isRecording || _isRecordingLocked) return;
    _unfocusInput();
    if (!_composerExpanded) return;
    setState(() {
      _composerExpanded = false;
      _composerMode = _ComposerMode.text;
      _pendingKeyboardOpen = false;
    });
    _maybeScrollToBottomIfNearBottom();
    _scheduleMeasureComposer();
  }

  void _setComposerMode(_ComposerMode mode) {
    if (_isRecording || _isRecordingLocked) return;
    setState(() {
      _composerExpanded = true;
      _composerMode = mode;
      _pendingKeyboardOpen = mode == _ComposerMode.text;
    });
    if (mode == _ComposerMode.text) {
      _focusNode.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _unfocusInput();
      });
    }
    _maybeScrollToBottomIfNearBottom();
    _scheduleMeasureComposer();
    _scheduleMeasureInputBar();
  }

  void _toggleEmojiPanel() {
    if (_emojiOpen) {
      _setComposerMode(_ComposerMode.text);
    } else {
      _setComposerMode(_ComposerMode.emoji);
    }
  }

  void _toggleToolsPanel() {
    if (_toolsOpen) {
      _setComposerMode(_ComposerMode.text);
    } else {
      _setComposerMode(_ComposerMode.tools);
    }
  }

  void _toggleVoiceMode() {
    if (_isRecordingLocked) {
      unawaited(_stopVoiceRecordingAndMaybeSend(send: true));
      return;
    }
    if (_isRecording) return;
    if (_voiceOpen) {
      _setComposerMode(_ComposerMode.text);
    } else {
      _setComposerMode(_ComposerMode.voice);
    }
  }

  Rect? _composerRect() {
    final ctx = _composerKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  Rect? _inputBarRect() {
    final ctx = _inputBarKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  bool _isPointInComposerOrInputBar(Offset p) {
    const pad = 26.0;
    final composer = _composerRect();
    final inputBar = _inputBarRect();
    if (composer == null && inputBar == null) return true;
    for (final r in [composer, inputBar]) {
      if (r == null) continue;
      final inflated = Rect.fromLTRB(
          r.left - pad, r.top - pad, r.right + pad, r.bottom + pad);
      if (inflated.contains(p)) return true;
    }
    return false;
  }

  void _initMessages() {
    final now = DateTime.now();
    _messages.add(ChatMessage(
      id: 'aide_greeting_00',
      senderId: _kAideId,
      receiverId: _kMyUserId,
      content: '你好！正在读取你的 Identity…',
      createdAt: now.subtract(const Duration(minutes: 2)),
    ));
    _messages.add(ChatMessage(
      id: 'aide_todo_00',
      senderId: _kAideId,
      receiverId: _kMyUserId,
      content: '任务加载中…',
      createdAt: now.subtract(const Duration(minutes: 1)),
    ));
  }

  void _applyGreetingWithIdentity(String? id) {
    final idx = _messages.indexWhere((m) => m.id == 'aide_greeting_00');
    if (idx < 0) return;
    final old = _messages[idx];
    final text = (id != null && id.isNotEmpty)
        ? (_isBound
            ? '你好，你的 IdentityID 是 $id。点击右上角头像可复制完整 ID；把它发给好友，对方在菜单中搜索你的 8 位 ID 即可开始聊天。'
            : '你好，我是 Aide。当前为临时身份，数据仅保存在此设备。绑定步骤：点击右上角头像 -> 账号与安全 -> 开始绑定。')
        : '未能读取 Identity，请重启应用后再试。';
    _messages[idx] = ChatMessage(
      id: old.id,
      senderId: old.senderId,
      receiverId: old.receiverId,
      content: text,
      createdAt: old.createdAt,
    );
    _applyTaskChecklist();
  }

  void _applyTaskChecklist() {
    final idx = _messages.indexWhere((m) => m.id == 'aide_todo_00');
    if (idx < 0) return;
    final old = _messages[idx];
    final checkBind = _isBound ? '✅' : '🔴';
    final checkTalk = _hasAnyFriendConversation ? '✅' : '⚪';
    final checkBackup = _hasBackedUpKey ? '✅' : '⚪';
    _messages[idx] = ChatMessage(
      id: old.id,
      senderId: old.senderId,
      receiverId: old.receiverId,
      content:
          '今日任务\n$checkBind 绑定身份（邮箱或 TRX）\n$checkTalk 首次沟通（向好友发消息）\n$checkBackup 备份私钥',
      createdAt: old.createdAt,
    );
  }

  void _maybeScrollToBottomIfNearBottom() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 80) {
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        _suppressScrollCollapse = true;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ).then((_) {
          if (mounted) _suppressScrollCollapse = false;
        });
      }
    });
  }

  void _sendMessage() {
    if (_controller.text.isEmpty) return;
    final raw = _controller.text;
    final reply = _replyToMessageText;
    final text =
        reply == null || reply.trim().isEmpty ? raw : '回复「${reply.trim()}」\n$raw';
    final newMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: _kMyUserId,
      receiverId: _kAideId,
      content: text,
      createdAt: DateTime.now(),
    );
    _controller.clear();
    if (_replyToMessageId != null) {
      setState(() {
        _replyToMessageId = null;
        _replyToMessageText = null;
      });
    }
    setState(() => _messages.add(newMsg));
    // TODO(阶段5): 对接后端 API — socket.emit('send_message', { toUserId: 'aide', content })
    _afterSendCollapseComposer();
    _scrollToBottom();
  }

  void _afterSendCollapseComposer() {
    if (!mounted) return;
    _unfocusInput();
    setState(() {
      _composerExpanded = false;
      _composerMode = _ComposerMode.text;
      _pendingKeyboardOpen = false;
    });
    _maybeScrollToBottomIfNearBottom();
    _scheduleMeasureComposer();
  }

  void _startVoiceRecording({required Offset globalPosition}) {
    if (_isRecording || _isRecordingLocked) return;
    final now = DateTime.now();
    setState(() {
      _composerExpanded = true;
      _composerMode = _ComposerMode.voice;
      _pendingKeyboardOpen = false;
      _isRecording = true;
      _isRecordingLocked = false;
      _recordingDuration = Duration.zero;
      _recordStartAt = now;
      _recordStartGlobal = globalPosition;
    });
    _recordingTimer?.cancel();
    _recordingTimer =
        Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      if (_recordStartAt == null) return;
      setState(() {
        _recordingDuration = DateTime.now().difference(_recordStartAt!);
      });
    });
  }

  Future<void> _stopVoiceRecordingAndMaybeSend(
      {required bool send}) async {
    if (!_isRecording && !_isRecordingLocked) return;
    _recordingTimer?.cancel();
    _recordingTimer = null;
    final startAt = _recordStartAt;
    final duration = startAt == null
        ? Duration.zero
        : DateTime.now().difference(startAt);
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordStartAt = null;
      _recordingDuration = Duration.zero;
    });
    if (!send || duration.inMilliseconds < _minRecordMs) {
      _afterSendCollapseComposer();
      return;
    }
    final content = '（语音 ${duration.inSeconds}s）';
    // TODO(阶段5): 对接后端 API — 语音消息
    final newMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      senderId: _kMyUserId,
      receiverId: _kAideId,
      content: content,
      createdAt: DateTime.now(),
    );
    setState(() => _messages.add(newMsg));
    _afterSendCollapseComposer();
    _scrollToBottom();
  }

  void _insertTextAtCursor(String text) {
    final value = _controller.value;
    final selection = value.selection;
    final start =
        selection.start < 0 ? value.text.length : selection.start;
    final end = selection.end < 0 ? value.text.length : selection.end;
    final newText = value.text.replaceRange(start, end, text);
    final newOffset = start + text.length;
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
      composing: TextRange.empty,
    );
  }

  Future<void> _showMessageMenu(
      BuildContext bubbleContext, ChatMessage msg) async {
    final box = bubbleContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlay = Overlay.of(bubbleContext).context.findRenderObject()
        as RenderBox;
    final rect =
        box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    setState(() => _activeMessageMenuId = msg.id);
    final action = await showMenu<_MessageAction>(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side:
            BorderSide(color: Colors.black.withOpacity(0.06), width: 0.8),
      ),
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: _MessageAction.reply, child: Text('回复')),
        PopupMenuItem(value: _MessageAction.copy, child: Text('复制')),
        PopupMenuItem(
            value: _MessageAction.forward, child: Text('转发')),
        PopupMenuItem(
            value: _MessageAction.multiSelect, child: Text('多选')),
        PopupMenuItem(value: _MessageAction.delete, child: Text('删除')),
      ],
    );
    if (!mounted) return;
    setState(() => _activeMessageMenuId = null);
    if (action == null) return;
    switch (action) {
      case _MessageAction.reply:
        setState(() {
          _replyToMessageId = msg.id;
          _replyToMessageText = msg.text;
        });
        _focusNode.requestFocus();
        break;
      case _MessageAction.copy:
        await Clipboard.setData(ClipboardData(text: msg.text));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('已复制'),
              duration: Duration(milliseconds: 900)),
        );
        break;
      case _MessageAction.forward:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开发中')),
        );
        break;
      case _MessageAction.multiSelect:
        setState(() {
          _multiSelectMode = true;
          _selectedMessageIds.add(msg.id);
        });
        break;
      case _MessageAction.delete:
        setState(() => _messages.removeWhere((m) => m.id == msg.id));
        break;
    }
  }

  Future<void> _deleteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    setState(() {
      _messages.removeWhere((m) => _selectedMessageIds.contains(m.id));
      _selectedMessageIds.clear();
      _multiSelectMode = false;
    });
  }

  void _openTool(String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (context) => ToolPlaceholderPage(title: title)),
    );
  }

  void _openAccountAndSafety() {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      Navigator.pop(context);
    }
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const ToolPlaceholderPage(title: '账号与安全'),
      ),
    );
  }

  void _startBindingStatusPolling() {
    _bindingPollTimer?.cancel();
    _bindingPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final flag = await _storage.read(key: kRootIdIsBoundStorageKey);
      final nextBound = flag == '1';
      if (!mounted) return;
      if (nextBound != _isBound) {
        setState(() {
          _isBound = nextBound;
          _showUnboundBanner = !nextBound;
          _isVerifying = false;
          _verifyingLabel = '';
          _applyGreetingWithIdentity(_localIdentityId);
        });
      }
    });
  }

  Future<void> _markBackupKeyViewed() async {
    await _storage.write(key: kRootIdBackedUpKeyStorageKey, value: '1');
    if (!mounted) return;
    setState(() {
      _hasBackedUpKey = true;
      _applyTaskChecklist();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已标记：Identity Key 已查看',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onInverseSurface,
              ),
        ),
        backgroundColor: Theme.of(context).colorScheme.inverseSurface,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<void> _showEmailChallengeDialog() async {
    final code =
        (100000 + (DateTime.now().millisecondsSinceEpoch % 900000)).toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('📧 邮箱挑战'),
          content: Text(
              '请从你的邮箱发送验证码 $code 至 loginX@rootid.net\n\n等待监听中...'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('验证成功'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    setState(() {
      _isVerifying = true;
      _verifyingLabel = '验证中...（邮箱挑战）';
    });
    await _onVerificationSuccess();
  }

  Future<void> _showTrxChallengeDialog() async {
    final suffix = (DateTime.now().millisecondsSinceEpoch % 9000 + 1000);
    final amount = '1.${suffix.toString().padLeft(4, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('💰 TRX 转账'),
          content:
              Text('请向地址 TRX-ROOTID-VERIFY-001 转账 $amount TRX\n\n等待链上确认...'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('验证成功'),
            ),
          ],
        );
      },
    );
    if (ok != true || !mounted) return;
    setState(() {
      _isVerifying = true;
      _verifyingLabel = '验证中...（TRX 转账）';
    });
    await _onVerificationSuccess();
  }

  Future<void> _onVerificationSuccess() async {
    await _storage.write(key: kRootIdIsBoundStorageKey, value: '1');
    if (!mounted) return;
    setState(() {
      _isBound = true;
      _showUnboundBanner = false;
      _isVerifying = false;
      _verifyingLabel = '';
      _applyGreetingWithIdentity(_localIdentityId);
    });
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const ToolPlaceholderPage(title: '密码设置'),
      ),
    );
  }

  void _sendQuickReply(String text) {
    _controller.text = text;
    _sendMessage();
  }

  Future<void> _onFollowSearchSubmitted() async {
    final raw = _followSearchController.text.trim().toLowerCase();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    void showSnack(String msg) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onInverseSurface,
            ),
          ),
          backgroundColor: scheme.inverseSurface,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
        ),
      );
    }

    if (raw.isEmpty) {
      showSnack('请输入对方的 8 位 IdentityID');
      return;
    }
    if (!_followIdPattern.hasMatch(raw)) {
      showSnack('请输入 8 位小写字母或数字（与 Identity 格式一致）');
      return;
    }

    final owner = SocketService.instance.identityId ??
        await DatabaseHelper.instance.readOwnerIdFromSecureStorage();
    if (!mounted) return;
    if (owner == null || owner.isEmpty) {
      showSnack('身份未就绪，请稍后再试');
      return;
    }
    if (raw == owner) {
      showSnack('不能添加自己为联系人');
      return;
    }

    await DatabaseHelper.instance.followContactByIdentityId(
      ownerId: owner,
      identityId: raw,
    );
    if (!mounted) return;
    _followSearchController.clear();
    FocusScope.of(context).unfocus();
    showSnack('已关注 $raw');
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => const HomePage(),
      ),
    );
  }

  String _formatRecordingDuration(Duration d) {
    final total = d.inSeconds;
    final mm = (total ~/ 60).toString().padLeft(2, '0');
    final ss = (total % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  bool _shouldShowTime(int index) {
    if (index == 0) return true;
    final cur = _messages[index].createdAt;
    final prev = _messages[index - 1].createdAt;
    return cur.difference(prev).inMinutes >= 3;
  }

  String _formatTimestamp(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);
    final time =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (date == today) return time;
    final yesterday = today.subtract(const Duration(days: 1));
    if (date == yesterday) return '昨天 $time';
    if (dt.year == now.year) return '${dt.month}/${dt.day} $time';
    return '${dt.year}/${dt.month}/${dt.day} $time';
  }

  Future<void> _loadLocalIdentity() async {
    final id = await DatabaseHelper.instance.readOwnerIdFromSecureStorage();
    final boundFlag = await _storage.read(key: kRootIdIsBoundStorageKey);
    final backupFlag = await _storage.read(key: kRootIdBackedUpKeyStorageKey);
    bool hasConversation = false;
    if (id != null && id.isNotEmpty) {
      try {
        final contacts =
            await DatabaseHelper.instance.getContactsDescending(ownerId: id);
        hasConversation = contacts.any((c) {
          final v = (c['identity_id'] as String?) ?? '';
          return v.isNotEmpty && v.toLowerCase() != 'aide';
        });
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _localIdentityId = id;
      _isBound = boundFlag == '1';
      _hasBackedUpKey = backupFlag == '1';
      _hasAnyFriendConversation = hasConversation;
      _applyGreetingWithIdentity(id);
      _showUnboundBanner = !(boundFlag == '1');
    });
    if (id != null && id.isNotEmpty) {
      unawaited(_loadAideHistoryFromDb(id));
    }
    _startBindingStatusPolling();
  }

  Future<void> _loadAideHistoryFromDb(String ownerId) async {
    List<ChatMessage> lower = <ChatMessage>[];
    List<ChatMessage> upper = <ChatMessage>[];
    try {
      lower = await DatabaseHelper.instance.getMessagesByChatId(
        ownerId: ownerId,
        chatWith: _kAideId,
      );
    } catch (_) {}
    try {
      upper = await DatabaseHelper.instance.getMessagesByChatId(
        ownerId: ownerId,
        chatWith: 'Aide',
      );
    } catch (_) {}

    final merged = <String, ChatMessage>{};
    for (final m in [...lower, ...upper]) {
      merged[m.id] = m;
    }
    final history = merged.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (!mounted) return;
    final greetingIndex =
        _messages.indexWhere((m) => m.id == 'aide_greeting_00');
    if (greetingIndex < 0) return;
    final greeting = _messages[greetingIndex];
    setState(() {
      _messages = <ChatMessage>[greeting, ...history];
    });
    _scrollToBottom();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadLocalIdentity());
    _initMessages();
    _socketHintSub = SocketService.instance.connectionHints.listen((msg) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            msg,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onInverseSurface,
            ),
          ),
          backgroundColor: scheme.inverseSurface,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(16),
          duration: const Duration(seconds: 8),
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(SocketService.instance.connect());
      _scrollToBottom();
    });
    _focusNode.addListener(() {
      final next = _focusNode.hasFocus;
      if (next == _inputHasFocus) return;
      setState(() => _inputHasFocus = next);
      if (next) {
        _maybeScrollToBottomIfNearBottom();
        _scrollToBottom();
        _scheduleMeasureComposer();
        _scheduleMeasureInputBar();
      }
    });
    _waveController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800));
    _rippleController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _menuController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _ringFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      lowerBound: 0.0,
      upperBound: 1.0,
    )..value = 1.0;
  }

  @override
  void dispose() {
    _socketHintSub?.cancel();
    _bindingPollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _waveController.dispose();
    _rippleController.dispose();
    _menuController.dispose();
    _ringFadeController.dispose();
    _controller.dispose();
    _followSearchController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final viewInsetBottom =
        View.of(context).viewInsets.bottom / View.of(context).devicePixelRatio;
    final wasClosed = _lastViewInsetBottom <= 0.0;
    final isOpen = viewInsetBottom > 0.0;
    _lastViewInsetBottom = viewInsetBottom;
    if (wasClosed && isOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _scheduleMeasureInputBar();
        _scheduleMeasureComposer();
        _scrollToBottom();
      });
    }
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isMe = msg.isMe;
    final selected = _selectedMessageIds.contains(msg.id);
    final menuActive = _activeMessageMenuId == msg.id;

    final Widget selector = SizedBox(
      width: 34,
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (selected ? Colors.black : Colors.white)
                .withOpacity(selected ? 0.18 : 0.9),
            border: Border.all(
                color: Colors.black.withOpacity(0.12), width: 0.8),
          ),
          alignment: Alignment.center,
          child: Icon(
            selected ? Icons.check : Icons.circle_outlined,
            size: 12,
            color: Colors.black.withOpacity(selected ? 0.65 : 0.18),
          ),
        ),
      ),
    );

    return Builder(
      builder: (bubbleContext) => GestureDetector(
        onTap: () {
          if (!_multiSelectMode) return;
          setState(() {
            if (selected) {
              _selectedMessageIds.remove(msg.id);
            } else {
              _selectedMessageIds.add(msg.id);
            }
          });
        },
        onLongPressStart: (_) => _showMessageMenu(bubbleContext, msg),
        child: Row(
          children: [
            if (_multiSelectMode) selector,
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  top: 4,
                  bottom: 4,
                  left: isMe ? 60 : 16,
                  right: isMe ? 16 : 60,
                ),
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: isMe
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Flexible(
                          child: Stack(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.grey[800]
                                      : Colors.grey[200],
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(18),
                                    topRight: const Radius.circular(18),
                                    bottomLeft: isMe
                                        ? const Radius.circular(18)
                                        : const Radius.circular(4),
                                    bottomRight: isMe
                                        ? const Radius.circular(4)
                                        : const Radius.circular(18),
                                  ),
                                ),
                                child: Text(
                                  msg.text,
                                  style: TextStyle(
                                    color:
                                        isMe ? Colors.white : Colors.black87,
                                    fontSize: 15,
                                    height: 1.4,
                                  ),
                                  softWrap: true,
                                ),
                              ),
                              if (menuActive || selected)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.only(
                                          topLeft:
                                              const Radius.circular(18),
                                          topRight:
                                              const Radius.circular(18),
                                          bottomLeft: isMe
                                              ? const Radius.circular(18)
                                              : const Radius.circular(4),
                                          bottomRight: isMe
                                              ? const Radius.circular(4)
                                              : const Radius.circular(18),
                                        ),
                                        color: Colors.black.withOpacity(
                                            menuActive ? 0.05 : 0.03),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMultiSelectActionBar() {
    if (!_multiSelectMode) return const SizedBox.shrink();
    final enabled = _selectedMessageIds.isNotEmpty;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border(
                top: BorderSide(
                    color: Colors.black.withOpacity(0.06), width: 0.8)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: enabled
                      ? () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('开发中')),
                          );
                        }
                      : null,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black
                          .withOpacity(enabled ? 0.06 : 0.02),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.black.withOpacity(0.06),
                          width: 0.8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '转发',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: Colors.black
                            .withOpacity(enabled ? 0.75 : 0.3),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: InkWell(
                  onTap: enabled ? _deleteSelectedMessages : null,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black
                          .withOpacity(enabled ? 0.06 : 0.02),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: Colors.black.withOpacity(0.06),
                          width: 0.8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '删除',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: Colors.black
                            .withOpacity(enabled ? 0.75 : 0.3),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              InkWell(
                onTap: () {
                  setState(() {
                    _multiSelectMode = false;
                    _selectedMessageIds.clear();
                  });
                },
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 40,
                  width: 60,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: Colors.black.withOpacity(0.06),
                        width: 0.8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '取消',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: Colors.black.withOpacity(0.55),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComposer({required double animPanelHeight}) {
    const double avatarHeight = 40;
    const double avatarWidth = avatarHeight * 1.2;
    const double inputMinHeight = 40;
    const double barRadius = 9;
    const Color inputBg = Color(0xFFFCFCFC);
    const String aideAvatarUrl = 'https://picsum.photos/id/1074/300/300';

    final kb = MediaQuery.of(context).viewInsets.bottom;
    if (kb > _lastKeyboardHeight + 1) {
      _lastKeyboardHeight = kb;
    }

    if (_composerExpanded &&
        _composerMode == _ComposerMode.text &&
        kb > 0 &&
        _pendingKeyboardOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_pendingKeyboardOpen) return;
        setState(() => _pendingKeyboardOpen = false);
      });
    }

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        top: false,
        child: KeyedSubtree(
          key: _composerKey,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, _) {
                    final hasText = value.text.trim().isNotEmpty;
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final maxWidth = constraints.maxWidth;
                        final targetWidth =
                            _inputExpanded ? maxWidth : (maxWidth * 0.7);
                        return TweenAnimationBuilder<double>(
                          tween: Tween<double>(end: targetWidth),
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          builder: (context, width, _) {
                            _scheduleMeasureInputBar();
                            return Align(
                              alignment: Alignment.bottomCenter,
                              child: SizedBox(
                                key: _inputBarKey,
                                width: width,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (_replyToMessageText != null &&
                                        _replyToMessageText!
                                            .trim()
                                            .isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            bottom: 6),
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(barRadius),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: inputBg,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      barRadius),
                                              border: Border.all(
                                                  width: 0.9,
                                                  color: const Color(
                                                      0x14000000)),
                                            ),
                                            padding:
                                                const EdgeInsets.fromLTRB(
                                                    12, 8, 10, 8),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _replyToMessageText!
                                                        .trim(),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: Colors.black
                                                          .withOpacity(0.65),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                InkResponse(
                                                  onTap: () {
                                                    setState(() {
                                                      _replyToMessageId =
                                                          null;
                                                      _replyToMessageText =
                                                          null;
                                                    });
                                                  },
                                                  radius: 18,
                                                  child: Icon(
                                                    Icons.close,
                                                    size: 18,
                                                    color: Colors.black
                                                        .withOpacity(0.55),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (_isRecording || _isRecordingLocked)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                            bottom: 6),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            border: Border.all(
                                                color: Colors.black
                                                    .withOpacity(0.06),
                                                width: 0.8),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black
                                                    .withOpacity(0.04),
                                                blurRadius: 18,
                                                offset:
                                                    const Offset(0, 8),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Row(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.arrow_upward,
                                                      size: 14,
                                                      color: Colors.black
                                                          .withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Icon(Icons.lock,
                                                      size: 14,
                                                      color: Colors.black
                                                          .withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '锁定',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black
                                                          .withOpacity(0.55),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Row(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                      Icons.mic_none,
                                                      size: 16,
                                                      color:
                                                          Colors.black54),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    '录音中',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black
                                                          .withOpacity(0.75),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Text(
                                                    _formatRecordingDuration(
                                                        _recordingDuration),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black
                                                          .withOpacity(0.35),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Row(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.arrow_back,
                                                      size: 14,
                                                      color: Colors.black
                                                          .withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Icon(Icons.close,
                                                      size: 14,
                                                      color: Colors.black
                                                          .withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '取消',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black
                                                          .withOpacity(0.55),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    AnimatedSize(
                                      duration:
                                          const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      alignment: Alignment.bottomCenter,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                            minHeight: inputMinHeight),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 8),
                                              child: SizedBox(
                                                height: 32,
                                                child: ListView(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  children: [
                                                    _QuickReplyChip(
                                                      label: '验证状态',
                                                      onTap: () =>
                                                          _sendQuickReply(
                                                              '验证状态'),
                                                    ),
                                                    _QuickReplyChip(
                                                      label: '备份身份',
                                                      onTap: () =>
                                                          _sendQuickReply(
                                                              '备份身份'),
                                                    ),
                                                    _QuickReplyChip(
                                                      label: '使用说明',
                                                      onTap: () =>
                                                          _sendQuickReply(
                                                              '使用说明'),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      barRadius),
                                              child: Container(
                                            key: _translateMenuAnchorKey,
                                            decoration: BoxDecoration(
                                              color: inputBg,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      barRadius),
                                              border: Border.all(
                                                  width: 0.9,
                                                  color: const Color(
                                                      0x14000000)),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(
                                                          0xFF000000)
                                                      .withOpacity(0.07),
                                                  blurRadius: 22,
                                                  offset:
                                                      const Offset(0, 10),
                                                ),
                                                BoxShadow(
                                                  color: Colors.white
                                                      .withOpacity(0.9),
                                                  blurRadius: 1,
                                                  offset:
                                                      const Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                              child: Padding(
                                                padding: const EdgeInsets.only(
                                                    right: 10),
                                                child: Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                children: [
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            bottom: 0),
                                                    child: ClipRRect(
                                                      borderRadius:
                                                          const BorderRadius
                                                              .only(
                                                        topLeft:
                                                            Radius.circular(
                                                                barRadius),
                                                        bottomLeft:
                                                            Radius.circular(
                                                                barRadius),
                                                      ),
                                                      child: SizedBox(
                                                        width: avatarWidth,
                                                        height: avatarHeight,
                                                        child: ShaderMask(
                                                          shaderCallback:
                                                              (Rect bounds) {
                                                            return const LinearGradient(
                                                              begin: Alignment
                                                                  .centerLeft,
                                                              end: Alignment
                                                                  .centerRight,
                                                              colors: [
                                                                Colors.black,
                                                                Colors.black,
                                                                Colors
                                                                    .black54,
                                                                Colors
                                                                    .transparent,
                                                              ],
                                                              stops: [
                                                                0.0,
                                                                0.88,
                                                                0.94,
                                                                1.0,
                                                              ],
                                                            ).createShader(
                                                                bounds);
                                                          },
                                                          blendMode:
                                                              BlendMode.dstIn,
                                                          child: ClipRRect(
                                                            borderRadius:
                                                                const BorderRadius
                                                                    .only(
                                                              topLeft: Radius
                                                                  .circular(
                                                                      barRadius),
                                                              bottomLeft:
                                                                  Radius
                                                                      .circular(
                                                                          barRadius),
                                                            ),
                                                            child:
                                                                Image.network(
                                                              aideAvatarUrl,
                                                              width:
                                                                  avatarWidth,
                                                              height:
                                                                  avatarHeight,
                                                              fit: BoxFit
                                                                  .cover,
                                                              errorBuilder:
                                                                  (context,
                                                                      error,
                                                                      stackTrace) {
                                                                return const SizedBox
                                                                    .expand();
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                              vertical: 3),
                                                      child: Row(
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          Expanded(
                                                            child: TextField(
                                                              controller:
                                                                  _controller,
                                                              focusNode:
                                                                  _focusNode,
                                                              minLines: 1,
                                                              maxLines: 4,
                                                              keyboardType:
                                                                  TextInputType
                                                                      .multiline,
                                                              textInputAction:
                                                                  TextInputAction
                                                                      .newline,
                                                              textAlignVertical:
                                                                  TextAlignVertical
                                                                      .center,
                                                              style:
                                                                  const TextStyle(
                                                                fontSize:
                                                                    14.5,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                height: 1.25,
                                                                color: Color(
                                                                    0xFF111111),
                                                              ),
                                                              onTap: () {
                                                                if (_composerMode !=
                                                                        _ComposerMode
                                                                            .text ||
                                                                    !_composerExpanded) {
                                                                  _setComposerMode(
                                                                      _ComposerMode
                                                                          .text);
                                                                } else {
                                                                  _focusNode
                                                                      .requestFocus();
                                                                  _scheduleMeasureComposer();
                                                                }
                                                              },
                                                              decoration:
                                                                  InputDecoration(
                                                                border:
                                                                    InputBorder
                                                                        .none,
                                                                isDense: true,
                                                                contentPadding:
                                                                    const EdgeInsets
                                                                        .only(
                                                                        top: 5,
                                                                        bottom:
                                                                            5),
                                                                fillColor:
                                                                    Colors
                                                                        .transparent,
                                                                filled: false,
                                                                hintText: hasText
                                                                    ? null
                                                                    : 'Aide',
                                                                hintStyle:
                                                                    TextStyle(
                                                                  fontSize:
                                                                      12,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                  color: Colors
                                                                      .black
                                                                      .withOpacity(
                                                                          0.35),
                                                                  letterSpacing:
                                                                      0.2,
                                                                ),
                                                              ),
                                                              onSubmitted:
                                                                  (_) =>
                                                                      _sendMessage(),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                  if (!hasText) ...[
                                                    KeyedSubtree(
                                                      key: _micAnchorKey,
                                                      child: GestureDetector(
                                                        behavior:
                                                            HitTestBehavior
                                                                .opaque,
                                                        onLongPressStart: (d) =>
                                                            _startVoiceRecording(
                                                                globalPosition:
                                                                    d.globalPosition),
                                                        onLongPressMoveUpdate:
                                                            (d) {
                                                          final start =
                                                              _recordStartGlobal;
                                                          if (start == null)
                                                            return;
                                                          final dx = d
                                                                  .globalPosition
                                                                  .dx -
                                                              start.dx;
                                                          final dy = d
                                                                  .globalPosition
                                                                  .dy -
                                                              start.dy;
                                                          if (!_isRecordingLocked &&
                                                              dy <= _lockDy) {
                                                            setState(() =>
                                                                _isRecordingLocked =
                                                                    true);
                                                          }
                                                          if (dx <=
                                                              _cancelDx) {
                                                            _stopVoiceRecordingAndMaybeSend(
                                                                send: false);
                                                          }
                                                        },
                                                        onLongPressEnd: (_) {
                                                          if (_isRecordingLocked)
                                                            return;
                                                          _stopVoiceRecordingAndMaybeSend(
                                                              send: true);
                                                        },
                                                        onLongPressCancel: () =>
                                                            _stopVoiceRecordingAndMaybeSend(
                                                                send: false),
                                                        child: _AideRoundIconButton(
                                                          icon: Icons.mic_none,
                                                          onPressed:
                                                              _toggleVoiceMode,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    _AideRoundIconButton(
                                                      icon: Icons
                                                          .emoji_emotions_outlined,
                                                      onPressed:
                                                          _toggleEmojiPanel,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    _AideRoundIconButton(
                                                      icon: Icons.add,
                                                      onPressed:
                                                          _toggleToolsPanel,
                                                    ),
                                                  ] else
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets
                                                              .only(
                                                              bottom: 2),
                                                      child:
                                                          _AideSendButton(
                                                              onPressed:
                                                                  _sendMessage),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
                SizedBox(
                  height: animPanelHeight,
                  child: ClipRect(
                    child: Builder(
                      builder: (context) {
                        if (animPanelHeight <= 0)
                          return const SizedBox.shrink();
                        if (_composerMode == _ComposerMode.text) {
                          return const SizedBox.shrink();
                        }
                        if (_composerMode == _ComposerMode.emoji) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border(
                                  top: BorderSide(
                                      color:
                                          Colors.black.withOpacity(0.06),
                                      width: 0.8)),
                            ),
                            child: EmojiPanel(
                                onSelected: (emoji) =>
                                    _insertTextAtCursor(emoji)),
                          );
                        }
                        if (_composerMode == _ComposerMode.tools) {
                          return ToolsDrawerPanel(
                            height: animPanelHeight,
                            onSelected: (title) {
                              _setComposerMode(_ComposerMode.text);
                              _openTool(title);
                            },
                          );
                        }
                        return Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border(
                                top: BorderSide(
                                    color: Colors.black.withOpacity(0.06),
                                    width: 0.8)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    final topPad = MediaQuery.of(context).padding.top;
    final targetPanelHeight = (_composerExpanded && _composerMode != _ComposerMode.text) ||
            (_composerExpanded && _composerMode == _ComposerMode.text && _pendingKeyboardOpen && kb == 0)
        ? _desiredExpandedHeight(context)
        : 0.0;
    return PopScope(
      canPop: Navigator.of(context).canPop(),
      child: TweenAnimationBuilder<double>(
      tween: Tween<double>(end: targetPanelHeight),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      builder: (context, animPanelHeight, _) {
        final kb = MediaQuery.of(context).viewInsets.bottom;
        final kbArea = _composerMode == _ComposerMode.text ? kb : 0.0;
        final barH = _inputBarHeight ?? 120.0;
        final safeB = MediaQuery.of(context).padding.bottom;
        final showUnboundBanner = !_isBound && _showUnboundBanner;
        final bannerHeight = showUnboundBanner ? 106.0 : 0.0;
        final bottomOccupied = _multiSelectMode
            ? 56 + safeB
            : barH + animPanelHeight + kbArea + safeB;
        return Scaffold(
          key: _scaffoldKey,
          resizeToAvoidBottomInset: false,
          backgroundColor: Colors.white,
          drawerEnableOpenDragGesture: true,
          drawer: Drawer(
            backgroundColor: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  UserIdentityCard(identityId: _localIdentityId),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: TextField(
                      controller: _followSearchController,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.search,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: Theme.of(context).colorScheme.onSurface,
                            fontFamily: 'Courier',
                            fontWeight: FontWeight.w600,
                          ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索并关注：输入 8 位 IdentityID',
                        hintStyle:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                        filled: true,
                        fillColor: Theme.of(context).colorScheme.surface,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.25),
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.2),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.65),
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        suffixIcon: IconButton(
                          icon: Icon(
                            Icons.search,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          onPressed: () =>
                              unawaited(_onFollowSearchSubmitted()),
                        ),
                      ),
                      onSubmitted: (_) => unawaited(_onFollowSearchSubmitted()),
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.12),
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.shield_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      '账号与安全',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    trailing: !_isBound
                        ? Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                          )
                        : null,
                    onTap: _openAccountAndSafety,
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.vpn_key_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      'Identity Key',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      unawaited(_markBackupKeyViewed());
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.settings_outlined,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      '通用设置',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              const ToolPlaceholderPage(title: '通用设置'),
                        ),
                      );
                    },
                  ),
                  ListTile(
                    leading: Icon(
                      Icons.help_outline,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      '帮助与反馈',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              const ToolPlaceholderPage(title: '帮助与反馈'),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          body: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (d) {
              if (d.globalPosition.dx < 30) {
                _dragStartX = d.globalPosition.dx;
                _dragCurrentX = d.globalPosition.dx;
              } else {
                _dragStartX = null;
              }
            },
            onHorizontalDragUpdate: (d) {
              if (_dragStartX != null) _dragCurrentX = d.globalPosition.dx;
            },
            onHorizontalDragEnd: (d) {
              final start = _dragStartX;
              _dragStartX = null;
              if (start != null && (_dragCurrentX - start) > 80) {
                debugPrint('Aide → HomePage');
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HomePage()),
                );
              }
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _AideEncryptionPainter()),
                ),
                if (showUnboundBanner)
                  Positioned(
                    top: topPad + 44,
                    left: 10,
                    right: 10,
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 38),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFECEC),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFFFD1D1),
                          width: 0.8,
                        ),
                      ),
                      padding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '当前为临时身份，换设备数据不保留',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.onSurface,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              TextButton(
                                onPressed: _isVerifying
                                    ? null
                                    : () => unawaited(_showEmailChallengeDialog()),
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      Theme.of(context).colorScheme.onSurface,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 28),
                                ),
                                child: const Text('📧 邮箱挑战'),
                              ),
                              const SizedBox(width: 6),
                              TextButton(
                                onPressed: _isVerifying
                                    ? null
                                    : () => unawaited(_showTrxChallengeDialog()),
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      Theme.of(context).colorScheme.onSurface,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 2),
                                  minimumSize: const Size(0, 28),
                                ),
                                child: const Text('💰 TRX 转账'),
                              ),
                              const Spacer(),
                              IconButton(
                                onPressed: () {
                                  setState(() => _showUnboundBanner = false);
                                },
                                iconSize: 16,
                                splashRadius: 16,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                          if (_isVerifying)
                            Text(
                              _verifyingLabel,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.onSurface,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                        ],
                      ),
                    ),
                  ),
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTapDown: (d) {
                    final size = MediaQuery.sizeOf(context);
                    final safeHitTop = size.height - bottomOccupied - 12;
                    if (d.globalPosition.dy >= safeHitTop) return;
                    if (_isPointInComposerOrInputBar(d.globalPosition)) return;
                    _collapseComposer();
                  },
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is ScrollStartNotification) {
                        if (_suppressScrollCollapse) return false;
                        _collapseComposer();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: EdgeInsets.fromLTRB(
                        10,
                        topPad + 16 + bannerHeight + (showUnboundBanner ? 8 : 0),
                        10,
                        bottomOccupied,
                      ),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        final showTime = _shouldShowTime(index);
                        return Column(
                          children: [
                            if (showTime)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 24),
                                child: Center(
                                  child: Text(
                                    _formatTimestamp(msg.timestamp),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.black.withOpacity(0.15),
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            _buildMessageBubble(msg),
                          ],
                        );
                      },
                    ),
                  ),
                ),
                if (_multiSelectMode)
                  _buildMultiSelectActionBar()
                else
                  _buildComposer(animPanelHeight: animPanelHeight),
              ],
            ),
          ),
        );
      },
    ),
    );
  }
}

class _AideEncryptionPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.025)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    const double step = 70.0;
    for (double i = 0; i < size.width; i += step) {
      for (double j = 0; j < size.height; j += step) {
        if ((i + j) % 140 == 0) {
          canvas.drawRect(
              Rect.fromCenter(
                  center: Offset(i + 35, j + 35), width: 10, height: 12),
              paint);
          canvas.drawArc(
              Rect.fromCenter(
                  center: Offset(i + 35, j + 27), width: 8, height: 8),
              3.14,
              3.14,
              false,
              paint);
        } else if ((i + j) % 210 == 0) {
          canvas.drawCircle(Offset(i + 20, j + 20), 8, paint);
          canvas.drawCircle(Offset(i + 20, j + 20), 4, paint);
        } else {
          canvas.drawCircle(Offset(i, j), 1.2, paint);
          if (i + step < size.width) {
            canvas.drawLine(
                Offset(i, j), Offset(i + step, j + step / 2), paint);
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class _QuickReplyChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _QuickReplyChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        label: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.onSurface,
              ),
        ),
        onPressed: onTap,
        backgroundColor:
            Theme.of(context).colorScheme.surfaceContainerHighest,
        side: BorderSide(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
          width: 0.8,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    );
  }
}

class _AideRoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _AideRoundIconButton(
      {required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFFDFDFD),
            border: Border.all(
                color: Colors.black.withOpacity(0.08), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Center(
              child: Icon(icon,
                  color: Colors.black.withOpacity(0.62), size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _AideSendButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _AideSendButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF111111), Color(0xFF2A2A2A)],
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.20),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: const Center(
              child: Icon(Icons.north, color: Colors.white, size: 18),
            ),
          ),
        ),
      ),
    );
  }
}
