import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import '../models/chat_message.dart';
import '../services/database_helper.dart';
import '../services/socket_service.dart';
import '../widgets/emoji_panel.dart';
import '../widgets/tools_drawer.dart';
import 'tool_placeholder_page.dart';

const _kMyUserId = 'me';

typedef Message = ChatMessage;

extension MessageUI on ChatMessage {
  String get text => content;
  String get type {
    final my = SocketService.instance.identityId;
    if (my != null && senderId == my) return 'me';
    if (senderId == _kMyUserId) return 'me';
    return 'friend';
  }

  DateTime get timestamp => createdAt;
  bool get isRecalled => false;
}

enum _TranslateMode {
  off,
  toZh,
  toEn,
}

enum _ComposerMode {
  text,
  voice,
  emoji,
  tools,
}

enum _MessageAction {
  reply,
  copy,
  forward,
  multiSelect,
  delete,
  translate,
}

class ChatPage extends StatefulWidget {
  final String receiverId;
  final String receiverName;

  const ChatPage({
    super.key, 
    this.receiverId = 'public',
    this.receiverName = 'Chat',
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with TickerProviderStateMixin, WidgetsBindingObserver {
  StreamSubscription<SocketIncomingChat>? _socketSub;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _translateMenuAnchorKey = GlobalKey();
  final GlobalKey _inputBarKey = GlobalKey();

  _ComposerMode _composerMode = _ComposerMode.text;
  bool _composerExpanded = false;
  final GlobalKey _composerKey = GlobalKey();

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
  bool _suppressScrollCollapse = false;
  final GlobalKey _micAnchorKey = GlobalKey();

  double _lastKeyboardHeight = 320;
  bool _pendingKeyboardOpen = false;
  double _lastViewInsetBottom = 0;

  void _unfocusInput() {
    FocusScope.of(context).unfocus();
  }
  final bool _isInputActive = true;
  final bool _isMenuOpen = false;
  late AnimationController _waveController;
  late AnimationController _rippleController;
  late AnimationController _menuController;
  late AnimationController _ringFadeController;
  bool _inputHasFocus = false;

  String? _activeMessageMenuId;
  String? _replyToMessageId;
  String? _replyToMessageText;
  bool _multiSelectMode = false;
  final Set<String> _selectedMessageIds = <String>{};
  final Map<String, String> _translatedMessageById = <String, String>{};

  List<ChatMessage> _messages = [];

  static const int _minRecordMs = 900;
  static const double _cancelDx = -78;
  static const double _lockDy = -78;

  bool get _emojiOpen => _composerMode == _ComposerMode.emoji;
  bool get _toolsOpen => _composerMode == _ComposerMode.tools;
  bool get _voiceOpen => _composerMode == _ComposerMode.voice;

  double _desiredExpandedHeight(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    if (kb > _lastKeyboardHeight + 1) {
      _lastKeyboardHeight = kb;
    }
    return _lastKeyboardHeight;
  }

  void _scheduleMeasureComposer() {
    if (_composerMeasureScheduled) return;
    _composerMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _composerMeasureScheduled = false;
      final ctx = _composerKey.currentContext;
      if (ctx == null) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height;
      final changed = _composerHeight == null || (height - _composerHeight!).abs() > 1.0;
      if (!changed) return;
      if (!mounted) return;
      setState(() => _composerHeight = height);
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
      final height = box.size.height;
      final changed = _inputBarHeight == null || (height - _inputBarHeight!).abs() > 0.5;
      if (!changed) return;
      if (!mounted) return;
      setState(() => _inputBarHeight = height);
    });
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

  bool _isPointInComposerOrInputBar(Offset globalPosition) {
    final composer = _composerRect();
    final inputBar = _inputBarRect();
    if (composer == null && inputBar == null) return true;

    const pad = 26.0;
    if (composer != null) {
      final inflated = Rect.fromLTRB(
        composer.left - pad,
        composer.top - pad,
        composer.right + pad,
        composer.bottom + pad,
      );
      if (inflated.contains(globalPosition)) return true;
    }
    if (inputBar != null) {
      final inflated = Rect.fromLTRB(
        inputBar.left - pad,
        inputBar.top - pad,
        inputBar.right + pad,
        inputBar.bottom + pad,
      );
      if (inflated.contains(globalPosition)) return true;
    }
    return false;
  }

  Future<void> _forwardSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    final selected = _messages.where((m) => _selectedMessageIds.contains(m.id)).toList();
    selected.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final text = selected.map((e) => e.content).join('\n\n— — —\n\n');
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ForwardPlaceholderPage(messageText: text),
      ),
    );
  }

  Future<void> _deleteSelectedMessages() async {
    if (_selectedMessageIds.isEmpty) return;
    final selected =
        _messages.where((m) => _selectedMessageIds.contains(m.id)).toList();
    await _deleteMessageRows(selected);
    if (!mounted) return;
    setState(() {
      _messages.removeWhere((m) => _selectedMessageIds.contains(m.id));
      _selectedMessageIds.clear();
      _multiSelectMode = false;
    });
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
            border: Border(top: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.8)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: enabled ? _forwardSelectedMessages : null,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(enabled ? 0.06 : 0.02),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '转发',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: Colors.black.withOpacity(enabled ? 0.75 : 0.3),
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
                      color: Colors.black.withOpacity(enabled ? 0.06 : 0.02),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '删除',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: Colors.black.withOpacity(enabled ? 0.75 : 0.3),
                      ),
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

  _TranslateMode _translateMode = _TranslateMode.off;
  String _translatedPreview = '';
  Timer? _inputLongPressTimer;

  bool get _inputExpanded {
    return _inputHasFocus || _controller.text.trim().isNotEmpty;
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

  String _formatRecordingDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    final mm = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final ss = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
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
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!mounted) return;
      if (_recordStartAt == null) return;
      setState(() {
        _recordingDuration = DateTime.now().difference(_recordStartAt!);
      });
    });
  }

  Future<void> _stopVoiceRecordingAndMaybeSend({required bool send}) async {
    if (!_isRecording && !_isRecordingLocked) return;

    _recordingTimer?.cancel();
    _recordingTimer = null;

    final startAt = _recordStartAt;
    final duration = (startAt == null) ? Duration.zero : DateTime.now().difference(startAt);
    setState(() {
      _isRecording = false;
      _isRecordingLocked = false;
      _recordStartAt = null;
      _recordingDuration = Duration.zero;
    });

    if (!send) {
      _afterSendCollapseComposer();
      return;
    }
    if (duration.inMilliseconds < _minRecordMs) {
      _afterSendCollapseComposer();
      return;
    }

    final content = '（语音 ${duration.inSeconds}s）';
    final msg = await SocketService.instance.sendChat(
      toId: widget.receiverId,
      content: content,
    );
    if (!mounted) return;
    if (msg != null) {
      setState(() => _messages.add(msg));
    }

    _afterSendCollapseComposer();
    _scrollToBottom();
  }

  void _insertTextAtCursor(String text) {
    final value = _controller.value;
    final selection = value.selection;
    final start = selection.start < 0 ? value.text.length : selection.start;
    final end = selection.end < 0 ? value.text.length : selection.end;
    final newText = value.text.replaceRange(start, end, text);
    final newOffset = start + text.length;
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
      composing: TextRange.empty,
    );
  }

  Future<void> _showMessageMenu(BuildContext bubbleContext, ChatMessage msg) async {
    final box = bubbleContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlay = Overlay.of(bubbleContext).context.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;

    setState(() => _activeMessageMenuId = msg.id);

    final action = await showMenu<_MessageAction>(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.8),
      ),
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: _MessageAction.reply, child: Text('回复')),
        PopupMenuItem(value: _MessageAction.copy, child: Text('复制')),
        PopupMenuItem(value: _MessageAction.forward, child: Text('转发')),
        PopupMenuItem(value: _MessageAction.multiSelect, child: Text('多选')),
        PopupMenuItem(value: _MessageAction.delete, child: Text('删除')),
        PopupMenuItem(value: _MessageAction.translate, child: Text('翻译')),
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
          const SnackBar(content: Text('已复制'), duration: Duration(milliseconds: 900)),
        );
        break;
      case _MessageAction.forward:
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => _ForwardPlaceholderPage(messageText: msg.text),
          ),
        );
        break;
      case _MessageAction.multiSelect:
        setState(() {
          _multiSelectMode = true;
          _selectedMessageIds.add(msg.id);
        });
        break;
      case _MessageAction.delete:
        await _deleteMessageRows([msg]);
        if (!mounted) return;
        setState(() => _messages.removeWhere((m) => m.id == msg.id));
        break;
      case _MessageAction.translate:
        setState(() {
          if (_translatedMessageById.containsKey(msg.id)) {
            _translatedMessageById.remove(msg.id);
          } else {
            final translated = _looksLikeChinese(msg.text) ? '(EN) ${msg.text}' : '（中文）${msg.text}';
            _translatedMessageById[msg.id] = translated;
          }
        });
        break;
    }
  }

  void _maybeScrollToBottomIfNearBottom() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 80) {
      _scrollToBottom();
    }
  }
  void _openTool(String title) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ToolPlaceholderPage(title: title),
      ),
    );
  }

  Future<void> _loadHistoryFromDb() async {
    final owner = SocketService.instance.identityId ??
        await DatabaseHelper.instance.readOwnerIdFromSecureStorage();
    if (owner == null || owner.isEmpty || !mounted) return;
    final list = await DatabaseHelper.instance.getMessagesByChatId(
      ownerId: owner,
      chatWith: widget.receiverId,
    );
    if (!mounted) return;
    setState(() => _messages = list);
  }

  Future<void> _deleteMessageRows(Iterable<ChatMessage> items) async {
    final owner = SocketService.instance.identityId ??
        await DatabaseHelper.instance.readOwnerIdFromSecureStorage();
    if (owner == null) return;
    final ids = <int>[];
    for (final m in items) {
      final rid = DatabaseHelper.tryParseDbRowId(m.id);
      if (rid != null) ids.add(rid);
    }
    if (ids.isNotEmpty) {
      await DatabaseHelper.instance.deleteMessagesByLocalIds(
        ownerId: owner,
        localRowIds: ids,
      );
    }
  }

  static const List<String> _networkAvatars = [
    'https://picsum.photos/id/1025/300/300',
    'https://picsum.photos/id/1005/300/300',
    'https://picsum.photos/id/1011/300/300',
    'https://picsum.photos/id/1012/300/300',
    'https://picsum.photos/id/1015/300/300',
    'https://picsum.photos/id/1027/300/300',
    'https://picsum.photos/id/1035/300/300',
    'https://picsum.photos/id/1040/300/300',
    'https://picsum.photos/id/1062/300/300',
  ];

  String _avatarUrlForPeer() {
    final name = widget.receiverName.trim();
    final i = (name.isEmpty ? 0 : name.hashCode.abs()) % _networkAvatars.length;
    return _networkAvatars[i];
  }

  bool _looksLikeChinese(String text) {
    return RegExp(r'[\u4e00-\u9fff]').hasMatch(text);
  }

  String _fakeTranslate(String text, _TranslateMode mode) {
    final t = text.trim();
    if (t.isEmpty) return '';
    if (mode == _TranslateMode.toZh) {
      return _looksLikeChinese(t) ? t : '（中文）$t';
    }
    if (mode == _TranslateMode.toEn) {
      return _looksLikeChinese(t) ? '(EN) $t' : t;
    }
    return '';
  }

  void _updateTranslatePreview() {
    if (_translateMode == _TranslateMode.off) {
      if (_translatedPreview.isNotEmpty) {
        setState(() => _translatedPreview = '');
      }
      return;
    }

    final preview = _fakeTranslate(_controller.text, _translateMode);
    if (preview != _translatedPreview) {
      setState(() => _translatedPreview = preview);
    }
  }

  Future<void> _showTranslateMenu() async {
    final box = _translateMenuAnchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final selected = await showMenu<_TranslateMode>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: _TranslateMode.toZh, child: Text('翻译为中文')),
        PopupMenuItem(value: _TranslateMode.toEn, child: Text('翻译为英文')),
        PopupMenuItem(value: _TranslateMode.off, child: Text('取消翻译')),
      ],
    );
    if (selected == null) return;
    setState(() => _translateMode = selected);
    _updateTranslatePreview();
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

  void _handleInputPointerDown(PointerDownEvent event) {
    _inputLongPressTimer?.cancel();
    _inputLongPressTimer = Timer(const Duration(milliseconds: 520), () {
      _showTranslateMenu();
    });
  }

  void _handleInputPointerUp(PointerEvent event) {
    _inputLongPressTimer?.cancel();
    _inputLongPressTimer = null;
  }

  Future<void> _sendTranslatedMessage() async {
    final text = _translatedPreview.trim();
    if (text.isEmpty) return;
    final msg = await SocketService.instance.sendChat(
      toId: widget.receiverId,
      content: text,
    );
    if (!mounted) return;
    if (msg != null) {
      setState(() => _messages.add(msg));
    }
    _controller.clear();
    _updateTranslatePreview();
    _afterSendCollapseComposer();
    _scrollToBottom();
  }

  String _formatTimestamp(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final beforeYesterday = today.subtract(const Duration(days: 2));
    final date = DateTime(dateTime.year, dateTime.month, dateTime.day);

    String timeStr = "${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}";

    if (date == today) {
      return timeStr;
    } else if (date == yesterday) {
      return "昨天 $timeStr";
    } else if (date == beforeYesterday) {
      return "前天 $timeStr";
    } else if (dateTime.year == now.year) {
      return "${dateTime.month}/${dateTime.day} $timeStr";
    } else {
      return "${dateTime.year}/${dateTime.month}/${dateTime.day} $timeStr";
    }
  }

  bool _shouldShowTime(int index, List<ChatMessage> messages) {
    if (index == 0) return true;
    final currentMsg = messages[index];
    final prevMsg = messages[index - 1];
    return currentMsg.timestamp.difference(prevMsg.timestamp).inMinutes >= 3;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadHistoryFromDb());
    _controller.addListener(_updateTranslatePreview);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom();
    });
    _socketSub = SocketService.instance.incomingChat.listen((event) {
      if (!mounted) return;
      if (event.message.senderId != widget.receiverId) return;
      setState(() => _messages.add(event.message));
      _scrollToBottom();
    });
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _menuController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _ringFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      lowerBound: 0.0,
      upperBound: 1.0,
    )..value = 1.0;
  }

  @override
  void dispose() {
    _socketSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _inputLongPressTimer?.cancel();
    _controller.removeListener(_updateTranslatePreview);
    _recordingTimer?.cancel();
    _recordingTimer = null;
    _waveController.dispose();
    _rippleController.dispose();
    _menuController.dispose();
    _ringFadeController.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final viewInsetBottom = View.of(context).viewInsets.bottom / View.of(context).devicePixelRatio;
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

  Future<void> _sendMessage() async {
    if (_controller.text.isEmpty) return;
    final raw = _controller.text;
    final reply = _replyToMessageText;
    final text = reply == null || reply.trim().isEmpty ? raw : '回复「${reply.trim()}」\n$raw';
    _controller.clear();
    if (_replyToMessageId != null) {
      setState(() {
        _replyToMessageId = null;
        _replyToMessageText = null;
      });
    }
    final msg = await SocketService.instance.sendChat(
      toId: widget.receiverId,
      content: text,
    );
    if (!mounted) return;
    if (msg != null) {
      setState(() => _messages.add(msg));
    }
    _afterSendCollapseComposer();
    _scrollToBottom();
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    bool isMe = msg.type == 'me';

    final selected = _selectedMessageIds.contains(msg.id);
    final menuActive = _activeMessageMenuId == msg.id;
    final translated = _translatedMessageById[msg.id];

    final Widget selector = SizedBox(
      width: 34,
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: (selected ? Colors.black : Colors.white).withOpacity(selected ? 0.18 : 0.9),
            border: Border.all(color: Colors.black.withOpacity(0.12), width: 0.8),
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
      builder: (bubbleContext) {
        return GestureDetector(
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
          onLongPressStart: (_) {
            _showMessageMenu(bubbleContext, msg);
          },
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
                  child: Row(
                    mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: Stack(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: isMe ? Colors.grey[800] : Colors.grey[200],
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(18),
                                  topRight: const Radius.circular(18),
                                  bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                                  bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg.text,
                                    style: TextStyle(
                                      color: isMe ? Colors.white : Colors.black87,
                                      fontSize: 15,
                                      height: 1.4,
                                    ),
                                    softWrap: true,
                                  ),
                                  if (translated != null) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      translated,
                                      style: TextStyle(
                                        color: isMe ? Colors.white.withOpacity(0.7) : Colors.black.withOpacity(0.55),
                                        fontSize: 12,
                                        height: 1.35,
                                      ),
                                      softWrap: true,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (menuActive || selected)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.only(
                                        topLeft: const Radius.circular(18),
                                        topRight: const Radius.circular(18),
                                        bottomLeft: isMe ? const Radius.circular(18) : const Radius.circular(4),
                                        bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(18),
                                      ),
                                      color: Colors.black.withOpacity(menuActive ? 0.05 : 0.03),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildOrbMenu() {
    if (!_isMenuOpen) return const SizedBox.shrink();
    return Positioned(
      bottom: 120,
      right: 30,
      child: Column(
        children: [
          FloatingActionButton(
            heroTag: 'camera',
            mini: true,
            onPressed: () {},
            child: const Icon(Icons.camera_alt),
          ),
          const SizedBox(height: 10),
          FloatingActionButton(
            heroTag: 'image',
            mini: true,
            onPressed: () {},
            child: const Icon(Icons.image),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer({required double animPanelHeight}) {
    const double avatarHeight = 40;
    const double avatarWidth = avatarHeight * 1.2;
    const double inputMinHeight = 40;
    const double barRadius = 9;
    const Color inputBg = Color(0xFFFCFCFC);

    final kb = MediaQuery.of(context).viewInsets.bottom;
    if (kb > _lastKeyboardHeight + 1) {
      _lastKeyboardHeight = kb;
    }

    if (_composerExpanded && _composerMode == _ComposerMode.text && kb > 0 && _pendingKeyboardOpen) {
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
                        final targetWidth = _inputExpanded ? maxWidth : (maxWidth * 0.7);
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
                                    if (_replyToMessageText != null && _replyToMessageText!.trim().isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(barRadius),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: inputBg,
                                              borderRadius: BorderRadius.circular(barRadius),
                                              border: Border.all(width: 0.9, color: const Color(0x14000000)),
                                            ),
                                            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _replyToMessageText!.trim(),
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w800,
                                                      color: Colors.black.withOpacity(0.65),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                InkResponse(
                                                  onTap: () {
                                                    setState(() {
                                                      _replyToMessageId = null;
                                                      _replyToMessageText = null;
                                                    });
                                                  },
                                                  radius: 18,
                                                  child: Icon(
                                                    Icons.close,
                                                    size: 18,
                                                    color: Colors.black.withOpacity(0.55),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    if (_translateMode != _TranslateMode.off && _translatedPreview.trim().isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(barRadius),
                                          child: Container(
                                            decoration: BoxDecoration(
                                              color: inputBg,
                                              borderRadius: BorderRadius.circular(barRadius),
                                              border: Border.all(width: 0.9, color: const Color(0x14000000)),
                                            ),
                                            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    _translatedPreview,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w800,
                                                      color: Colors.black.withOpacity(0.65),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                InkResponse(
                                                  onTap: _sendTranslatedMessage,
                                                  radius: 18,
                                                  child: Icon(
                                                    Icons.arrow_upward,
                                                    size: 18,
                                                    color: Colors.black.withOpacity(0.75),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      )
                                    else const SizedBox.shrink(),
                                    if (_isRecording || _isRecordingLocked)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withOpacity(0.04),
                                                blurRadius: 18,
                                                offset: const Offset(0, 8),
                                              ),
                                            ],
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.arrow_upward, size: 14, color: Colors.black.withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Icon(Icons.lock, size: 14, color: Colors.black.withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '锁定',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w900,
                                                      color: Colors.black.withOpacity(0.55),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(Icons.mic_none, size: 16, color: Colors.black54),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    '录音中',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w900,
                                                      color: Colors.black.withOpacity(0.75),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Text(
                                                    _formatRecordingDuration(_recordingDuration),
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w900,
                                                      color: Colors.black.withOpacity(0.35),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Icon(Icons.arrow_back, size: 14, color: Colors.black.withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Icon(Icons.close, size: 14, color: Colors.black.withOpacity(0.55)),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '取消',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      fontWeight: FontWeight.w900,
                                                      color: Colors.black.withOpacity(0.55),
                                                      letterSpacing: 0.2,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    AnimatedSize(
                                      duration: const Duration(milliseconds: 150),
                                      curve: Curves.easeOut,
                                      alignment: Alignment.bottomCenter,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(minHeight: inputMinHeight),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(barRadius),
                                          child: Container(
                                            key: _translateMenuAnchorKey,
                                            decoration: BoxDecoration(
                                              color: inputBg,
                                              borderRadius: BorderRadius.circular(barRadius),
                                              border: Border.all(width: 0.9, color: const Color(0x14000000)),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: const Color(0xFF000000).withOpacity(0.07),
                                                  blurRadius: 22,
                                                  offset: const Offset(0, 10),
                                                ),
                                                BoxShadow(
                                                  color: Colors.white.withOpacity(0.9),
                                                  blurRadius: 1,
                                                  offset: const Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.only(right: 10),
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Padding(
                                                    padding: const EdgeInsets.only(bottom: 0),
                                                    child: GestureDetector(
                                                      onTap: () {
                                                        // TODO(阶段5): 对接后端 API — 好友资料页
                                                        ScaffoldMessenger.of(context).showSnackBar(
                                                          const SnackBar(content: Text('开发中')),
                                                        );
                                                      },
                                                      child: ClipRRect(
                                                        borderRadius: const BorderRadius.only(
                                                          topLeft: Radius.circular(barRadius),
                                                          bottomLeft: Radius.circular(barRadius),
                                                        ),
                                                        child: Container(
                                                        width: avatarWidth,
                                                        height: avatarHeight,
                                                        child: ShaderMask(
                                                          shaderCallback: (Rect bounds) {
                                                            return const LinearGradient(
                                                              begin: Alignment.centerLeft,
                                                              end: Alignment.centerRight,
                                                              colors: [
                                                                Colors.black,
                                                                Colors.black,
                                                                Colors.black54,
                                                                Colors.transparent,
                                                              ],
                                                              stops: [
                                                                0.0,
                                                                0.88,
                                                                0.94,
                                                                1.0,
                                                              ],
                                                            ).createShader(bounds);
                                                          },
                                                          blendMode: BlendMode.dstIn,
                                                          child: ClipRRect(
                                                            borderRadius: const BorderRadius.only(
                                                              topLeft: Radius.circular(barRadius),
                                                              bottomLeft: Radius.circular(barRadius),
                                                            ),
                                                            child: Image.network(
                                                              _avatarUrlForPeer(),
                                                              width: avatarWidth,
                                                              height: avatarHeight,
                                                              fit: BoxFit.cover,
                                                              errorBuilder: (context, error, stackTrace) {
                                                                debugPrint('ChatPage avatar load failed: ${_avatarUrlForPeer()}\n$error');
                                                                return const SizedBox.expand();
                                                              },
                                                            ),
                                                          ),
                                                        ),
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Padding(
                                                      padding: const EdgeInsets.symmetric(vertical: 3),
                                                      child: Row(
                                                        crossAxisAlignment: CrossAxisAlignment.end,
                                                        children: [
                                                          Expanded(
                                                            child: Listener(
                                                              onPointerDown: _handleInputPointerDown,
                                                              onPointerUp: _handleInputPointerUp,
                                                              onPointerCancel: _handleInputPointerUp,
                                                              child: TextField(
                                                                controller: _controller,
                                                                focusNode: _focusNode,
                                                                minLines: 1,
                                                                maxLines: 4,
                                                                keyboardType: TextInputType.multiline,
                                                                textInputAction: TextInputAction.newline,
                                                                textAlignVertical: TextAlignVertical.center,
                                                                style: const TextStyle(
                                                                  fontSize: 14.5,
                                                                  fontWeight: FontWeight.w600,
                                                                  height: 1.25,
                                                                  color: Color(0xFF111111),
                                                                ),
                                                                onTap: () {
                                                                  if (_composerMode != _ComposerMode.text || !_composerExpanded) {
                                                                    _setComposerMode(_ComposerMode.text);
                                                                  } else {
                                                                    _focusNode.requestFocus();
                                                                    _scheduleMeasureComposer();
                                                                  }
                                                                },
                                                                decoration: InputDecoration(
                                                                  border: InputBorder.none,
                                                                  isDense: true,
                                                                  contentPadding: const EdgeInsets.only(top: 5, bottom: 5),
                                                                  fillColor: Colors.transparent,
                                                                  filled: false,
                                                                  hintText: hasText ? null : widget.receiverName,
                                                                  hintStyle: TextStyle(
                                                                    fontSize: 12,
                                                                    fontWeight: FontWeight.w700,
                                                                    color: Colors.black.withOpacity(0.35),
                                                                    letterSpacing: 0.2,
                                                                  ),
                                                                ),
                                                                onSubmitted: (_) {
                                                                  unawaited(_sendMessage());
                                                                },
                                                              ),
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
                                                        behavior: HitTestBehavior.opaque,
                                                        onLongPressStart: (d) => _startVoiceRecording(globalPosition: d.globalPosition),
                                                        onLongPressMoveUpdate: (d) {
                                                          final start = _recordStartGlobal;
                                                          if (start == null) return;
                                                          final dx = d.globalPosition.dx - start.dx;
                                                          final dy = d.globalPosition.dy - start.dy;

                                                          if (!_isRecordingLocked && dy <= _lockDy) {
                                                            setState(() => _isRecordingLocked = true);
                                                          }

                                                          if (dx <= _cancelDx) {
                                                            _stopVoiceRecordingAndMaybeSend(send: false);
                                                          }
                                                        },
                                                        onLongPressEnd: (_) {
                                                          if (_isRecordingLocked) return;
                                                          _stopVoiceRecordingAndMaybeSend(send: true);
                                                        },
                                                        onLongPressCancel: () => _stopVoiceRecordingAndMaybeSend(send: false),
                                                        child: _RoundIconButton(
                                                          icon: Icons.mic_none,
                                                          onPressed: _toggleVoiceMode,
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 6),
                                                    _RoundIconButton(
                                                      icon: Icons.emoji_emotions_outlined,
                                                      onPressed: _toggleEmojiPanel,
                                                    ),
                                                    const SizedBox(width: 6),
                                                    _RoundIconButton(
                                                      icon: Icons.add,
                                                      onPressed: _toggleToolsPanel,
                                                    ),
                                                  ] else
                                                    Padding(
                                                      padding: const EdgeInsets.only(bottom: 2),
                                                      child: _SendButton(
                                                        onPressed: () {
                                                          unawaited(_sendMessage());
                                                        },
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
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
                        if (animPanelHeight <= 0) return const SizedBox.shrink();
                        if (_composerMode == _ComposerMode.text) {
                          return const SizedBox.shrink();
                        }
                        if (_composerMode == _ComposerMode.emoji) {
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border(top: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.8)),
                            ),
                            child: EmojiPanel(onSelected: (emoji) => _insertTextAtCursor(emoji)),
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
                            border: Border(top: BorderSide(color: Colors.black.withOpacity(0.06), width: 0.8)),
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
        final bottomOccupied = _multiSelectMode
            ? 56 + safeB
            : barH + animPanelHeight + kbArea + safeB;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          backgroundColor: Colors.white,
          body: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: TelegramEncryptionPainter(),
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
                      16 + MediaQuery.of(context).padding.top,
                      10,
                      _isInputActive ? bottomOccupied : (bottomOccupied + 12),
                    ),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final showTime = _shouldShowTime(index, _messages);

                      return Column(
                        children: [
                          if (showTime)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 24),
                              child: Center(
                                child: Text(
                                  _formatTimestamp(message.timestamp),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.black.withOpacity(0.15),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          _buildMessageBubble(message),
                        ],
                      );
                    },
                  ),
                ),
              ),
              _buildOrbMenu(),
              if (_multiSelectMode)
                _buildMultiSelectActionBar()
              else if (_isInputActive)
                _buildComposer(animPanelHeight: animPanelHeight),
            ],
          ),
        );
      },
    ),
    );
  }
}

class _ForwardPlaceholderPage extends StatelessWidget {
  final String messageText;

  const _ForwardPlaceholderPage({
    required this.messageText,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('转发'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '转发占位页\n\n内容：\n$messageText',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Colors.black.withOpacity(0.7),
            height: 1.4,
          ),
        ),
      ),
    );
  }
}

class TelegramEncryptionPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.025)..strokeWidth = 1.2..style = PaintingStyle.stroke;
    const double step = 70.0;
    for (double i = 0; i < size.width; i += step) {
      for (double j = 0; j < size.height; j += step) {
        if ((i + j) % 140 == 0) {
          canvas.drawRect(Rect.fromCenter(center: Offset(i + 35, j + 35), width: 10, height: 12), paint);
          canvas.drawArc(Rect.fromCenter(center: Offset(i + 35, j + 27), width: 8, height: 8), 3.14, 3.14, false, paint);
        } else if ((i + j) % 210 == 0) {
          canvas.drawCircle(Offset(i + 20, j + 20), 8, paint);
          canvas.drawCircle(Offset(i + 20, j + 20), 4, paint);
        } else {
          canvas.drawCircle(Offset(i, j), 1.2, paint);
          if (i + step < size.width) {
            canvas.drawLine(Offset(i, j), Offset(i + step, j + step / 2), paint);
          }
        }
      }
    }
  }
  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
  });

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
            border: Border.all(color: Colors.black.withOpacity(0.08), width: 0.8),
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
              child: Icon(icon, color: Colors.black.withOpacity(0.62), size: 20),
            ),
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final VoidCallback onPressed;

  const _SendButton({
    required this.onPressed,
  });

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
              colors: [
                Color(0xFF111111),
                Color(0xFF2A2A2A),
              ],
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
