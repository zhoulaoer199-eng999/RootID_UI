import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/database_helper.dart';
import '../services/socket_service.dart';
import '../widgets/chat_list_item.dart';
import 'aide_page.dart';
import 'chat_page.dart';

class GroupMember {
  final String id;
  final String name;
  const GroupMember({required this.id, required this.name});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _kAideId = 'Aide';
  static const String _kAideName = 'Aide';
  static const String _kAideGreeting = '你好！我是你的助手 Aide。';

  StreamSubscription<void>? _contactsRefreshSub;
  List<Map<String, Object?>> _contactRows = [];

  static const double _glassSigma = 22;
  static const double _glassBaseA = 0.38;
  static const double _glassBaseB = 0.18;
  static const double _glassBorderA = 0.28;
  static const double _glassBorderW = 0.6;
  static const double _topGlassSigma = 22;
  static const double _topGlassBaseA = 0.42;
  static const double _topGlassBaseB = 0.18;
  static const double _topGlassBorderA = 0.32;
  static const double _topGlassBorderW = 0.7;

  LinearGradient _glassGradient() {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0, 0.32, 1],
      colors: [
        Colors.white.withOpacity(_glassBaseA),
        Colors.white.withOpacity(_glassBaseB),
        Colors.white.withOpacity(_glassBaseB * 0.78),
      ],
    );
  }

  LinearGradient _topGlassGradient() {
    return LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      stops: const [0, 0.32, 1],
      colors: [
        Colors.white.withOpacity(_topGlassBaseA),
        Colors.white.withOpacity(_topGlassBaseB),
        Colors.white.withOpacity(_topGlassBaseB * 0.78),
      ],
    );
  }

  final List<Map<String, String>> channels = [
    {'name': '对话'},
    {'name': '公司'},
    {'name': '朋友'},
    {'name': '家人'},
    {'name': '同学'},
  ];

  int _activeChannelIndex = 0;

  final Set<String> _pinnedThreads = <String>{};
  final Set<String> _mutedThreads = <String>{};
  final Set<String> _deletedThreads = <String>{};

  final Map<int, Set<String>> _groupMembers = <int, Set<String>>{};
  final Set<int> _mutedGroups = <int>{};
  final Set<int> _hiddenGroupHints = <int>{};
  bool _groupsInitialized = false;

  final Map<String, int> _seenReceivedTotals = <String, int>{};

  OverlayEntry? _quickReplyOverlay;
  String? _quickReplyThreadId;

  OverlayEntry? _groupMenuOverlay;

  static const List<String> _networkAvatars = [
    'https://picsum.photos/id/1003/300/300',
    'https://picsum.photos/id/1005/300/300',
    'https://picsum.photos/id/1011/300/300',
    'https://picsum.photos/id/1012/300/300',
    'https://picsum.photos/id/1015/300/300',
    'https://picsum.photos/id/1027/300/300',
    'https://picsum.photos/id/1035/300/300',
    'https://picsum.photos/id/1040/300/300',
    'https://picsum.photos/id/1062/300/300',
  ];

  void _togglePin(String threadId) {
    setState(() {
      if (_pinnedThreads.contains(threadId)) {
        _pinnedThreads.remove(threadId);
      } else {
        _pinnedThreads.add(threadId);
      }
    });
  }

  void _toggleMute(String threadId) {
    setState(() {
      if (_mutedThreads.contains(threadId)) {
        _mutedThreads.remove(threadId);
      } else {
        _mutedThreads.add(threadId);
      }
    });
  }

  void _deleteThread(BuildContext context, String threadId, String displayName) {
    if (threadId == _kAideId) {
      return;
    }
    setState(() {
      _deletedThreads.add(threadId);
      _pinnedThreads.remove(threadId);
      _mutedThreads.remove(threadId);
      if (_quickReplyThreadId == threadId) {
        _dismissQuickReply();
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已删除「$displayName」聊天记录（本地隐藏）'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _dismissGroupMenu() {
    _groupMenuOverlay?.remove();
    _groupMenuOverlay = null;
  }

  Future<void> _showGroupMenuAt({
    required BuildContext context,
    required Rect anchorRect,
    required int groupIndex,
    required List<GroupMember> available,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    _dismissGroupMenu();

    final overlayBox = Overlay.of(context).context.findRenderObject() as RenderBox;
    final maxWidth = overlayBox.size.width;
    final width = (anchorRect.width + 24).clamp(188.0, 260.0);
    final left = anchorRect.left.clamp(10.0, maxWidth - width - 10.0);
    final top = anchorRect.bottom + 6;
    final completer = Completer<String?>();

    Widget menuItem({required String title, required String value, bool isDanger = false}) {
      final color = isDanger ? Colors.redAccent : Colors.black;
      return InkWell(
        onTap: () {
          if (!completer.isCompleted) completer.complete(value);
          _dismissGroupMenu();
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final overlayEntry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  if (!completer.isCompleted) completer.complete(null);
                  _dismissGroupMenu();
                },
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: width,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      menuItem(title: '管理分组', value: 'members'),
                      _groupHairline(),
                      menuItem(title: _mutedGroups.contains(groupIndex) ? '开启通知' : '关闭通知', value: 'notify'),
                      _groupHairline(),
                      menuItem(title: '分组排序', value: 'sort'),
                      _groupHairline(),
                      menuItem(title: '创建分组', value: 'create'),
                      _groupHairline(),
                      menuItem(title: '删除分组', value: 'remove', isDanger: true),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _groupMenuOverlay = overlayEntry;
    Overlay.of(context).insert(overlayEntry);

    final action = await completer.future;
    if (action == null) return;
    if (!context.mounted) return;

    if (action == 'members') {
      // TODO(阶段5): 对接后端 API — 好友分组管理
      messenger.showSnackBar(
        const SnackBar(content: Text('开发中'), duration: Duration(seconds: 1)),
      );
      return;
    }

    if (action == 'notify') {
      setState(() {
        if (_mutedGroups.contains(groupIndex)) {
          _mutedGroups.remove(groupIndex);
        } else {
          _mutedGroups.add(groupIndex);
        }
      });
      return;
    }

    if (action == 'sort') {
      messenger.showSnackBar(
        const SnackBar(content: Text('分组排序（占位）'), duration: Duration(seconds: 1)),
      );
      return;
    }

    if (action == 'create') {
      final name = await _promptGroupName(context);
      if (!context.mounted) return;
      if (name == null || name.trim().isEmpty) return;
      setState(() {
        channels.add({'name': name.trim()});
        _groupMembers[channels.length - 1] = <String>{};
      });
      return;
    }

    if (action == 'remove') {
      if (groupIndex == 0) {
        messenger.showSnackBar(
          const SnackBar(content: Text('默认分组不可删除'), duration: Duration(seconds: 1)),
        );
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            backgroundColor: Colors.white,
            title: const Text('删除分组', style: TextStyle(fontWeight: FontWeight.w900)),
            content: const Text('确认删除该分组？'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('删除')),
            ],
          );
        },
      );
      if (ok != true) return;
      if (!context.mounted) return;
      setState(() {
        channels.removeAt(groupIndex);
        _groupMembers.remove(groupIndex);
        final shifted = <int, Set<String>>{};
        for (final e in _groupMembers.entries) {
          final k = e.key;
          if (k < groupIndex) {
            shifted[k] = e.value;
          } else if (k > groupIndex) {
            shifted[k - 1] = e.value;
          }
        }
        _groupMembers
          ..clear()
          ..addAll(shifted);
        _mutedGroups.remove(groupIndex);
        _activeChannelIndex = 0;
      });
    }
  }

  Widget _groupHairline() {
    return Divider(height: 1, thickness: 0.6, color: Colors.black.withOpacity(0.06));
  }

  Future<String?> _promptGroupName(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('创建分组', style: TextStyle(fontWeight: FontWeight.w900)),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '分组名称'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('创建')),
          ],
        );
      },
    );
  }

  void _dismissQuickReply() {
    _quickReplyOverlay?.remove();
    _quickReplyOverlay = null;
    _quickReplyThreadId = null;
  }

  Future<void> _showQuickReplyInline({
    required BuildContext itemContext,
    required String receiverId,
    required String receiverName,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    _dismissQuickReply();
    setState(() => _quickReplyThreadId = receiverId);

    final box = itemContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    if (box == null) {
      setState(() => _quickReplyThreadId = null);
      return;
    }

    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    const replies = ['好的', '我知道了', '稍等一下', '一会回复你', '现在方便'];
    final overlayEntry = OverlayEntry(
      builder: (context) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  _dismissQuickReply();
                  setState(() {});
                },
              ),
            ),
            Positioned(
              left: rect.left,
              top: rect.bottom + 6,
              width: rect.width,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final r in replies) ...[
                        InkWell(
                          onTap: () {
                            _dismissQuickReply();
                            setState(() {});
                            // TODO(阶段5): 对接后端 API — 发送消息
                            messenger.showSnackBar(
                              SnackBar(content: Text('已发送给「$receiverName」（开发中）'), duration: const Duration(seconds: 1)),
                            );
                          },
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    r,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w900,
                                      color: Colors.black,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (r != replies.last) _groupHairline(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    _quickReplyOverlay = overlayEntry;
    Overlay.of(context).insert(overlayEntry);
  }

  Widget _buildRootIdGroups({required int senderPeopleCount, required List<GroupMember> availableMembers}) {
    return Padding(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: _topGlassSigma, sigmaY: _topGlassSigma),
          child: Container(
            height: 36,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              gradient: _topGlassGradient(),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(_topGlassBorderA), width: _topGlassBorderW),
            ),
            child: Stack(
              children: [
                Row(
                  children: List.generate(channels.length, (index) {
                    return Expanded(
                      child: Builder(
                        builder: (tabContext) {
                          final bool isActive = index == _activeChannelIndex;
                          return GestureDetector(
                            onTap: () => setState(() => _activeChannelIndex = index),
                            onVerticalDragEnd: (details) {
                              final v = details.primaryVelocity;
                              if (v != null && v < -200) {
                                setState(() => _hiddenGroupHints.add(index));
                              }
                            },
                            onLongPressStart: (_) {
                              final box = tabContext.findRenderObject() as RenderBox?;
                              final overlay = Overlay.of(tabContext).context.findRenderObject() as RenderBox?;
                              if (box == null || overlay == null) return;
                              final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
                              _showGroupMenuAt(
                                context: tabContext,
                                anchorRect: rect,
                                groupIndex: index,
                                available: availableMembers,
                              );
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              curve: Curves.easeOut,
                              decoration: BoxDecoration(
                                color: isActive ? const Color(0xFFF2F2F7).withOpacity(0.72) : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                channels[index]['name']!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: isActive ? Colors.black87 : Colors.black54,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  }),
                ),
                if (senderPeopleCount > 0)
                  Positioned(
                    top: 4,
                    right: 6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.black.withOpacity(0.1), width: 0.6),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        senderPeopleCount.toString(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          color: Colors.black.withOpacity(0.62),
                          height: 1,
                        ),
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

  Widget _buildTechLogo(int pendingCount) {
    return GestureDetector(
      onTap: () {
        // TODO(阶段5): 对接后端 API — 好友请求列表
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('开发中'), duration: Duration(seconds: 1)),
        );
      },
      child: SizedBox(
        height: 22,
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'RootID',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'Courier',
                  letterSpacing: 0.4,
                  color: Color(0xFF0F172A),
                ),
              ),
              if (pendingCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _formatContactTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final timeStr =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    if (day == today) return timeStr;
    final yesterday = today.subtract(const Duration(days: 1));
    if (day == yesterday) return '昨天';
    if (d.year == now.year) return '${d.month}/${d.day}';
    return '${d.year}/${d.month}/${d.day}';
  }

  Future<void> _reloadContactsFromDb() async {
    final owner = SocketService.instance.identityId ??
        await DatabaseHelper.instance.readOwnerIdFromSecureStorage() ??
        'demo_owner';
    if (!mounted) return;
    List<Map<String, Object?>> rows = <Map<String, Object?>>[];
    try {
      rows = await DatabaseHelper.instance.getContactsDescending(ownerId: owner);
    } catch (_) {
      rows = <Map<String, Object?>>[];
    }
    if (!mounted) return;
    List<Map<String, Object?>> normalizedRows = rows
        .where((r) => (r['identity_id'] as String?) != _kAideId)
        .toList();
    normalizedRows = _ensureDemoContacts(
      ownerId: owner,
      rows: normalizedRows,
      minFriendCount: 9,
    );
    normalizedRows.insert(0, <String, Object?>{
      'identity_id': _kAideId,
      'owner_id': owner,
      'nickname': _kAideName,
      'avatar': null,
      'last_message': _kAideGreeting,
      'last_time': DateTime.now().millisecondsSinceEpoch,
    });
    setState(() {
      _deletedThreads.remove(_kAideId);
      _contactRows = normalizedRows;
      _groupsInitialized = false;
      _groupMembers.clear();
      _activeChannelIndex = 0;
      // 调试输出：确认 HomePage 列表数据已进入渲染层
      print('DEBUG: HomePage rows count = ${_contactRows.length}');
    });
  }

  List<Map<String, Object?>> _ensureDemoContacts({
    required String ownerId,
    required List<Map<String, Object?>> rows,
    required int minFriendCount,
  }) {
    final result = List<Map<String, Object?>>.from(rows);
    final existingIds = result
        .map((r) => (r['identity_id'] as String?)?.toLowerCase() ?? '')
        .toSet();
    if (result.length >= minFriendCount) {
      return result;
    }
    final mock = _buildMockContacts(ownerId: ownerId)
        .where((r) => !existingIds.contains(
            ((r['identity_id'] as String?) ?? '').toLowerCase()))
        .toList();
    final need = minFriendCount - result.length;
    result.addAll(mock.take(need));
    return result;
  }

  List<Map<String, Object?>> _buildMockContacts({required String ownerId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    const demo = <({String id, String nick, String msg})>[
      (id: 'rt7x9k2m', nick: 'User_01', msg: '最近怎么样？'),
      (id: 'a1b2c3d4', nick: 'Alpha', msg: '项目进度如何？'),
      (id: 'q9w8e7r6', nick: 'Tech_Support', msg: '今晚可以联调一下。'),
      (id: 'm4n8p2s6', nick: 'Nova', msg: '我刚看完你的更新。'),
      (id: 'z3x7c1v5', nick: 'Delta', msg: '我们明天同步计划。'),
      (id: 'h2j6k8l0', nick: 'Orbit', msg: '收到，稍后回复你。'),
      (id: 'u1i3o5p7', nick: 'Echo', msg: '这个思路很清晰。'),
      (id: 't6y4g2h8', nick: 'Matrix', msg: '测试环境已经准备好了。'),
      (id: 'b9n7m5k3', nick: 'Linker', msg: '有空的时候 call 我。'),
    ];

    return List<Map<String, Object?>>.generate(demo.length, (index) {
      final item = demo[index];
      return <String, Object?>{
        'identity_id': item.id,
        'owner_id': ownerId,
        'nickname': item.nick,
        'avatar': null,
        'last_message': item.msg,
        'last_time': now - ((index + 1) * 60000),
      };
    });
  }

  Widget _buildContactDock() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: _glassSigma, sigmaY: _glassSigma),
        child: Container(
          height: 100,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            gradient: _glassGradient(),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(_glassBorderA), width: _glassBorderW),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(4, (index) {
              final url = _networkAvatars[index % _networkAvatars.length];
              return GestureDetector(
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('开发中'), duration: Duration(seconds: 1)),
                ),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Image.network(
                      url,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        debugPrint('Dock avatar load failed: $url\n$error');
                        return const SizedBox.expand();
                      },
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    unawaited(_reloadContactsFromDb());
    _contactsRefreshSub =
        DatabaseHelper.instance.onContactsChanged.listen((_) {
      unawaited(_reloadContactsFromDb());
    });
  }

  @override
  void dispose() {
    _contactsRefreshSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 强制使用 RootID 1.0 的灰白主题色
    const Color mainBgColor = Color(0xFFF9F9F9);
    
    return Scaffold(
      backgroundColor: mainBgColor,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(22),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: _topGlassSigma, sigmaY: _topGlassSigma),
            child: Container(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              height: 22 + MediaQuery.of(context).padding.top,
              decoration: BoxDecoration(
                gradient: _topGlassGradient(),
                border: Border(
                  bottom: BorderSide(color: Colors.white.withOpacity(_topGlassBorderA), width: _topGlassBorderW),
                ),
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: _buildTechLogo(0),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          Transform.translate(
            offset: const Offset(0, 6),
            child: 
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              children: [
                Expanded(
                  child: Builder(
                    builder: (context) {
                      final List<_ChatPreview> previews = _contactRows.map((r) {
                        final id = r['identity_id']! as String;
                        final nick = r['nickname'] as String?;
                        final last = r['last_message'] as String? ?? '';
                        final t = r['last_time'] as int;
                        final displayMsg = last.isEmpty
                            ? '尚无消息，点进开始聊天'
                            : last;
                        return _ChatPreview(
                          name: (nick != null && nick.isNotEmpty) ? nick : id,
                          message: displayMsg,
                          time: _formatContactTime(t),
                          receiverId: id,
                        );
                      }).toList();

                      final List<_ChatPreview> visible = previews.where((p) {
                        final id = p.receiverId ?? 'mock_${p.name.hashCode.abs()}';
                        return !_deletedThreads.contains(id);
                      }).toList();

                      if (!_groupsInitialized) {
                        for (var gi = 0; gi < channels.length; gi++) {
                          _groupMembers.putIfAbsent(gi, () => <String>{});
                        }
                        for (final p in visible) {
                          final id = p.receiverId ?? 'mock_${p.name.hashCode.abs()}';
                          final gi = id.hashCode.abs() % channels.length;
                          _groupMembers[gi]!.add(id);
                          _groupMembers[0]!.add(id);
                        }
                        _groupsInitialized = true;
                      }

                      final groupSet = _groupMembers[_activeChannelIndex] ?? <String>{};
                      final List<_ChatPreview> scoped = _activeChannelIndex == 0
                          ? visible
                          : visible.where((p) => groupSet.contains(p.receiverId ?? 'mock_${p.name.hashCode.abs()}')).toList();

                      final List<_ChatPreview> ordered = [
                        ...scoped.where((p) => _pinnedThreads.contains(p.receiverId ?? 'mock_${p.name.hashCode.abs()}')),
                        ...scoped.where((p) => !_pinnedThreads.contains(p.receiverId ?? 'mock_${p.name.hashCode.abs()}')),
                      ];
                      final aideIndex = ordered.indexWhere((p) => p.receiverId == _kAideId);
                      if (aideIndex > 0) {
                        final aide = ordered.removeAt(aideIndex);
                        ordered.insert(0, aide);
                      }

                      final availableMembers = visible
                          .map(
                            (p) => GroupMember(
                              id: p.receiverId ?? 'mock_${p.name.hashCode.abs()}',
                              name: p.name,
                            ),
                          )
                          .toList();

                      final hideHints = _hiddenGroupHints.contains(_activeChannelIndex);
                      final senderPeopleCount = 0;

                      final List<Widget> listItems = List.generate(ordered.length, (index) {
                        final p = ordered[index];
                        final avatarPath = 'assets/girls/girl_${((index % 9) + 1).toString().padLeft(2, '0')}.png';
                        final receiverId = p.receiverId ?? 'mock_${p.name.hashCode.abs()}';
                        final receiverName = p.name;
                        return Builder(
                          builder: (itemContext) {
                            return ChatListItem(
                              key: ValueKey(receiverId),
                              chat: Chat(
                                name: p.name,
                                message: p.message,
                                time: p.time,
                                unread: hideHints ? 0 : 0,
                                avatar: avatarPath,
                              ),
                              avatarAsset: avatarPath,
                              networkAvatarUrl: _networkAvatars[index % _networkAvatars.length],
                              onAvatarTap: () {
                                // TODO(阶段5): 对接后端 API — 好友资料页
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('开发中'), duration: Duration(seconds: 1)),
                                );
                              },
                              selected: _quickReplyThreadId == receiverId,
                              onQuickReplyTap: () => _showQuickReplyInline(
                                itemContext: itemContext,
                                receiverId: receiverId,
                                receiverName: receiverName,
                              ),
                              onPin: () => _togglePin(receiverId),
                              onMute: () => _toggleMute(receiverId),
                              onDelete: () => _deleteThread(context, receiverId, receiverName),
                              onTap: () {
                                _dismissQuickReply();
                                setState(() {
                                  _seenReceivedTotals[receiverId] = 0;
                                });
                                if (receiverId == _kAideId) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (context) => const AidePage(),
                                    ),
                                  );
                                  return;
                                }
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ChatPage(
                                      receiverId: receiverId,
                                      receiverName: receiverName,
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        );
                      });

                      final theme = Theme.of(context);
                      final scheme = theme.colorScheme;

                      return Column(
                        children: [
                          _buildRootIdGroups(senderPeopleCount: senderPeopleCount, availableMembers: availableMembers),
                          const SizedBox(height: 0),
                          Expanded(
                            child: NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (n is ScrollStartNotification) {
                                  if (_quickReplyOverlay != null) {
                                    _dismissQuickReply();
                                    setState(() {});
                                  }
                                }
                                return false;
                              },
                              child: ordered.isEmpty
                                  ? ListView(
                                      padding: const EdgeInsets.fromLTRB(
                                          12, 32, 12, 140),
                                      children: [
                                        Icon(
                                          Icons.chat_bubble_outline,
                                          size: 48,
                                          color: scheme.onSurfaceVariant
                                              .withValues(alpha: 0.35),
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          '暂无会话',
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                            color: scheme.onSurface,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        Text(
                                          '暂无会话，前往 Aide 页左上角菜单可搜索并关注好友',
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.bodyMedium
                                              ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                            height: 1.45,
                                          ),
                                        ),
                                      ],
                                    )
                                  : ListView(
                                      padding: const EdgeInsets.fromLTRB(
                                          0, 0, 0, 140),
                                      children: listItems,
                                    ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 2),
              child: Transform.translate(
                offset: const Offset(0, 18),
                child: _buildContactDock(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatPreview {
  final String name;
  final String message;
  final String time;
  final String? receiverId;

  const _ChatPreview({
    required this.name,
    required this.message,
    required this.time,
    this.receiverId,
  });
}

class Chat {
  final String avatar;
  final String name;
  final String message;
  final String time;
  final int unread;

  Chat({
    required this.avatar,
    required this.name,
    required this.message,
    required this.time,
    required this.unread,
  });
}
