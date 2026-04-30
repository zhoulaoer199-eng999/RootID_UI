import 'package:flutter/material.dart';

class ToolsDrawerItem {
  final IconData icon;
  final String title;

  const ToolsDrawerItem({
    required this.icon,
    required this.title,
  });
}

Future<void> showToolsDrawer({
  required BuildContext context,
  required ValueChanged<String> onSelected,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.15),
    builder: (context) {
      return ToolsDrawerPanel(
        onSelected: (title) {
          Navigator.pop(context);
          onSelected(title);
        },
      );
    },
  );
}

class ToolsDrawerPanel extends StatelessWidget {
  final ValueChanged<String> onSelected;
  final double? height;

  const ToolsDrawerPanel({
    super.key,
    required this.onSelected,
    this.height,
  });

  static const List<List<ToolsDrawerItem>> _rows = [
    [
      ToolsDrawerItem(icon: Icons.photo_outlined, title: '照片'),
      ToolsDrawerItem(icon: Icons.photo_camera_outlined, title: '拍摄'),
      ToolsDrawerItem(icon: Icons.badge_outlined, title: '个人名片'),
      ToolsDrawerItem(icon: Icons.location_on_outlined, title: '位置'),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    final panelHeight = height ?? MediaQuery.of(context).size.height * 0.30;

    return SafeArea(
      top: false,
      child: Container(
        height: panelHeight,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Column(
                  children: [
                    for (int i = 0; i < _rows.length; i++) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (final item in _rows[i])
                            _ToolCell(
                              item: item,
                              onTap: () => onSelected(item.title),
                            ),
                        ],
                      ),
                      if (i != _rows.length - 1) const SizedBox(height: 10),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCell extends StatelessWidget {
  final ToolsDrawerItem item;
  final VoidCallback onTap;

  const _ToolCell({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cellWidth = (MediaQuery.of(context).size.width - 32 - 36) / 4;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: cellWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: const Color(0xFFF2F2F7),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Colors.black.withOpacity(0.05),
                  width: 0.8,
                ),
              ),
              child: Icon(
                item.icon,
                color: Colors.black87,
                size: 22,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.black.withOpacity(0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }
}