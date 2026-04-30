import 'package:flutter/material.dart';

Future<void> showEmojiPanel({
  required BuildContext context,
  required ValueChanged<String> onSelected,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.15),
    builder: (context) {
      return EmojiPanelSheet(onSelected: onSelected);
    },
  );
}

class EmojiPanelSheet extends StatelessWidget {
  final ValueChanged<String> onSelected;

  const EmojiPanelSheet({
    super.key,
    required this.onSelected,
  });

  static const _emojis = [
    '😀','😄','😁','😊','🙂','😉','😍','🥰','😘','😋','😎','🤗',
    '🥲','😅','😮','😲','😳','😤','😡','😭','😢','🥺','😴','🤯',
    '🤔','🤨','😶','🙄','😬','😇','🤝','👍','🙏','❤️','🔥','🎉',
  ];

  @override
  Widget build(BuildContext context) {
    final panelHeight = MediaQuery.of(context).size.height * 0.34;

    return SafeArea(
      top: false,
      child: Container(
        height: panelHeight,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: EmojiPanel(
          onSelected: (e) {
            Navigator.pop(context);
            onSelected(e);
          },
        ),
      ),
    );
  }
}

class EmojiPanel extends StatelessWidget {
  final ValueChanged<String> onSelected;

  const EmojiPanel({
    super.key,
    required this.onSelected,
  });

  static const _emojis = EmojiPanelSheet._emojis;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const SizedBox(height: 6),
          Center(
            child: SizedBox(
              width: 140,
              child: TabBar(
                labelColor: Colors.black,
                unselectedLabelColor: Colors.black54,
                indicatorColor: Colors.black,
                indicatorWeight: 2,
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(icon: Icon(Icons.emoji_emotions_outlined, size: 20)),
                  Tab(icon: Icon(Icons.favorite_border, size: 20)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              children: [
                _EmojiGridScroll(items: _emojis, onTap: onSelected),
                const _FavoritesPlaceholder(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmojiGridScroll extends StatelessWidget {
  final List<String> items;
  final ValueChanged<String> onTap;

  const _EmojiGridScroll({
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final e = items[index];
        return InkResponse(
          onTap: () => onTap(e),
          radius: 20,
          child: Center(
            child: Text(
              e,
              style: const TextStyle(fontSize: 28),
            ),
          ),
        );
      },
    );
  }
}

class _FavoritesPlaceholder extends StatelessWidget {
  const _FavoritesPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '收藏（占位）',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.black.withOpacity(0.45),
        ),
      ),
    );
  }
}