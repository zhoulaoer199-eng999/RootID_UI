import 'package:flutter/material.dart';
import '../pages/home_page.dart';

class ChatListItem extends StatefulWidget {
  final Chat chat;
  final VoidCallback onTap;
  final String avatarAsset;
  final String? networkAvatarUrl;
  final VoidCallback? onAvatarTap;
  final VoidCallback? onQuickReplyTap;
  final VoidCallback? onPin;
  final VoidCallback? onMute;
  final VoidCallback? onDelete;
  final bool selected;

  const ChatListItem({
    super.key,
    required this.chat,
    required this.onTap,
    required this.avatarAsset,
    this.networkAvatarUrl,
    this.onAvatarTap,
    this.onQuickReplyTap,
    this.onPin,
    this.onMute,
    this.onDelete,
    this.selected = false,
  });

  @override
  State<ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<ChatListItem> {
  static const double _actionWidth = 62;
  static const double _maxReveal = _actionWidth * 3;
  double _dx = 0;

  void _close() {
    if (_dx == 0) return;
    setState(() => _dx = 0);
  }

  void _openFull() {
    if (_dx == -_maxReveal) return;
    setState(() => _dx = -_maxReveal);
  }

  @override
  Widget build(BuildContext context) {
    final Color itemBgColor = Colors.grey.withOpacity(0.1);
    final String avatarPath = widget.avatarAsset;

    final double actionDx = _dx + _maxReveal;

    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: GestureDetector(
        onHorizontalDragUpdate: (details) {
          final next = (_dx + details.delta.dx).clamp(-_maxReveal, 0.0);
          if (next == _dx) return;
          setState(() => _dx = next);
        },
        onHorizontalDragEnd: (_) {
          final reveal = -_dx;
          if (reveal > _maxReveal * 0.45) {
            _openFull();
          } else {
            _close();
          }
        },
        onLongPress: () {
          if (widget.onQuickReplyTap == null) return;
          if (_dx != 0) {
            _close();
            return;
          }
          widget.onQuickReplyTap?.call();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: _dx == 0,
                  child: Transform.translate(
                    offset: Offset(actionDx, 0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _ActionButton(
                          width: _actionWidth,
                          title: '置顶',
                          background: Colors.white.withOpacity(0.55),
                          foreground: Colors.black.withOpacity(0.75),
                          onTap: () {
                            _close();
                            widget.onPin?.call();
                          },
                        ),
                        _ActionButton(
                          width: _actionWidth,
                          title: '静音',
                          background: Colors.white.withOpacity(0.55),
                          foreground: Colors.black.withOpacity(0.75),
                          onTap: () {
                            _close();
                            widget.onMute?.call();
                          },
                        ),
                        _ActionButton(
                          width: _actionWidth,
                          title: '删除',
                          background: Colors.redAccent.withOpacity(0.86),
                          foreground: Colors.white,
                          onTap: () {
                            _close();
                            widget.onDelete?.call();
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Transform.translate(
                offset: Offset(_dx, 0),
                child: InkWell(
                  onTap: () {
                    if (_dx != 0) {
                      _close();
                      return;
                    }
                    widget.onTap();
                  },
                  child: Container(
                    height: 72,
                    decoration: BoxDecoration(
                      color: itemBgColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.08),
                        width: 0.5,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                          InkResponse(
                            onTap: widget.onAvatarTap,
                            radius: 44,
                            child: SizedBox(
                              width: 86,
                              height: 72,
                              child: ClipRRect(
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  bottomLeft: Radius.circular(16),
                                ),
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
                                  child: widget.networkAvatarUrl != null
                                      ? Image.network(
                                          widget.networkAvatarUrl!,
                                          width: 86,
                                          height: 72,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) {
                                            debugPrint('ChatListItem network avatar failed: ${widget.networkAvatarUrl!}\n$error');
                                            return const SizedBox.expand();
                                          },
                                        )
                                      : Image.asset(
                                          avatarPath,
                                          width: 86,
                                          height: 72,
                                          fit: BoxFit.cover,
                                          errorBuilder: (context, error, stackTrace) {
                                            debugPrint('ChatListItem avatar load failed: $avatarPath\n$error');
                                            return const SizedBox.expand();
                                          },
                                        ),
                                ),
                              ),
                            ),
                          ),

                          const SizedBox(width: 0),

                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.chat.name,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Colors.black87,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    widget.chat.message,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.black54,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),

                          Padding(
                            padding: const EdgeInsets.only(
                              right: 16,
                              top: 16,
                              bottom: 16,
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  widget.chat.time,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey[600],
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                                if (widget.chat.unread > 0)
                                  Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[800],
                                      shape: BoxShape.circle,
                                    ),
                                    child: Text(
                                      '${widget.chat.unread}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox.shrink(),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (widget.selected)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: Colors.black.withOpacity(0.045),
                                border: Border.all(color: Colors.black.withOpacity(0.06), width: 0.8),
                              ),
                            ),
                          ),
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
    );
  }
}

class _ActionButton extends StatelessWidget {
  final double width;
  final String title;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;

  const _ActionButton({
    required this.width,
    required this.title,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: width,
        height: 72,
        color: background,
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: foreground,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}
