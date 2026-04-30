import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 侧边栏顶部：展示当前 IdentityID，点击复制（样式走 Theme）。
class UserIdentityCard extends StatelessWidget {
  final String? identityId;

  const UserIdentityCard({
    super.key,
    required this.identityId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final id = (identityId != null && identityId!.isNotEmpty) ? identityId! : '加载中…';

    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: InkWell(
        onTap: () async {
          if (identityId == null || identityId!.isEmpty) return;
          await Clipboard.setData(ClipboardData(text: identityId!));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '已复制 IdentityID',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onInverseSurface,
                ),
              ),
              backgroundColor: scheme.inverseSurface,
              behavior: SnackBarBehavior.floating,
              margin: const EdgeInsets.all(16),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '我的 Identity',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                id,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'Courier',
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '点击复制',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
