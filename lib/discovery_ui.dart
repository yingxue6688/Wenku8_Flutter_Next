import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_ui.dart';
import 'feed_filter.dart';

/// Descriptor for one website channel tab in [DiscoverChannelTabStrip].
@immutable
class DiscoverChannelTabItem {
  const DiscoverChannelTabItem({
    required this.keyName,
    required this.label,
    required this.selected,
    required this.onTap,
    this.tabKey,
  });

  final String keyName;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Key? tabKey;
}

/// Compact editorial underline tab bar shared by [DiscoverPage] and the
/// `筛选` sheet.
class DiscoverChannelTabStrip extends StatelessWidget {
  const DiscoverChannelTabStrip({
    super.key,
    required this.items,
    this.padding = const EdgeInsets.symmetric(horizontal: 2),
    this.showBaseline = true,
  });

  final List<DiscoverChannelTabItem> items;
  final EdgeInsetsGeometry padding;
  final bool showBaseline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final baselineColor = scheme.onSurface.withValues(alpha: .08);

    return Container(
      decoration: showBaseline
          ? BoxDecoration(
              border: Border(
                bottom: BorderSide(color: baselineColor, width: .8),
              ),
            )
          : null,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: padding,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final item in items) _ChannelTabButton(item: item),
          ],
        ),
      ),
    );
  }
}

class _ChannelTabButton extends StatelessWidget {
  const _ChannelTabButton({required this.item});

  final DiscoverChannelTabItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = item.selected;

    return Semantics(
      button: true,
      selected: active,
      label: item.label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: item.tabKey,
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            AppHaptics.play(context, HapticCue.selection);
            item.onTap();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(7, 4, 7, 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedDefaultTextStyle(
                  duration: NovelMotion.contact,
                  curve: NovelMotion.ease,
                  style: TextStyle(
                    fontSize: active ? 15 : 14,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    letterSpacing: -.15,
                    color: active
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant.withValues(alpha: .88),
                  ),
                  child: AppText(item.label, maxLines: 1, softWrap: false),
                ),
                const SizedBox(height: 5),
                AnimatedContainer(
                  duration: NovelMotion.contact,
                  curve: NovelMotion.ease,
                  width: active ? 18 : 0,
                  height: 2.4,
                  decoration: BoxDecoration(
                    color: active ? scheme.onSurface : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// High-contrast selectable filter pill aligned with [ArchiveDesign].
class DiscoverFilterChip extends StatelessWidget {
  const DiscoverFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.dense = false,
    this.leadingIcon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool dense;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(dense ? 9 : 10);

    final bgColor = selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: dark ? .07 : .042);
    final borderColor = selected
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: dark ? .15 : .10);
    final fgColor = selected
        ? scheme.surface
        : scheme.onSurface.withValues(alpha: .84);

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            AppHaptics.play(context, HapticCue.selection);
            onTap();
          },
          child: AnimatedContainer(
            duration: NovelMotion.contact,
            curve: NovelMotion.ease,
            padding: dense
                ? const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5)
                : const EdgeInsets.symmetric(horizontal: 12.5, vertical: 7.5),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: radius,
              border: Border.all(color: borderColor, width: .8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leadingIcon != null) ...[
                  ArchiveIcon(
                    leadingIcon!,
                    size: dense ? 13 : 14,
                    color: fgColor,
                  ),
                  const SizedBox(width: 4),
                ],
                AppText(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: dense ? 12.5 : 13,
                    height: 1.15,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: fgColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Framed editorial surface for inline filter rows inside [DiscoverPage].
class DiscoverInlineFilterCard extends StatelessWidget {
  const DiscoverInlineFilterCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(11, 9, 11, 10),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final fill = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: dark ? .045 : .026),
      scheme.surface,
    );

    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: dark ? .14 : .085),
          width: .8,
        ),
      ),
      child: child,
    );
  }
}

/// Compact header action button with optional active filter count badge.
class DiscoverHeaderIconAction extends StatelessWidget {
  const DiscoverHeaderIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badgeCount = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badgeCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final active = badgeCount > 0;
    final radius = BorderRadius.circular(10);

    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: () {
              AppHaptics.play(context, HapticCue.action);
              onTap();
            },
            child: AnimatedContainer(
              duration: NovelMotion.contact,
              curve: NovelMotion.ease,
              height: 34,
              padding: EdgeInsets.symmetric(horizontal: active ? 9 : 8),
              decoration: BoxDecoration(
                color: active
                    ? scheme.onSurface.withValues(alpha: dark ? .18 : .09)
                    : scheme.onSurface.withValues(alpha: dark ? .07 : .04),
                borderRadius: radius,
                border: Border.all(
                  color: scheme.onSurface.withValues(
                    alpha: active ? .28 : (dark ? .14 : .09),
                  ),
                  width: .8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ArchiveIcon(
                    icon,
                    size: 16,
                    color: scheme.onSurface.withValues(alpha: active ? 1 : .82),
                  ),
                  if (active) ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.onSurface,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: AppText(
                        '$badgeCount',
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          color: scheme.surface,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// High-contrast solid primary CTA button (`确定`) in [DiscoveryFilters].
class DiscoverPrimaryActionButton extends StatelessWidget {
  const DiscoverPrimaryActionButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: scheme.onSurface,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            AppHaptics.play(context, HapticCue.action);
            onPressed();
          },
          child: SizedBox(
            height: 44,
            child: Center(
              child: AppText(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: scheme.surface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Subtle hairline secondary action button (`重置` / `清空`) in [DiscoveryFilters].
class DiscoverSecondaryActionButton extends StatelessWidget {
  const DiscoverSecondaryActionButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(12);

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Material(
        color: scheme.onSurface.withValues(alpha: dark ? .06 : .035),
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled
              ? () {
                  AppHaptics.play(context, HapticCue.selection);
                  onPressed!();
                }
              : null,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: scheme.onSurface.withValues(
                  alpha: enabled ? (dark ? .20 : .14) : .07,
                ),
                width: .8,
              ),
            ),
            child: Center(
              child: AppText(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: enabled
                      ? scheme.onSurface
                      : scheme.onSurface.withValues(alpha: .36),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Multi-row category chip wrap that shows a compact preview with an `展开`
/// chip and expands smoothly on demand to display every category.
class DiscoverCollapsibleCategoryChips extends StatefulWidget {
  const DiscoverCollapsibleCategoryChips({
    super.key,
    required this.options,
    required this.selectedKey,
    required this.onSelected,
    this.collapsedCount = 8,
    this.chipKeyBuilder,
    this.toggleKey = const ValueKey('discover-inline-category-toggle'),
  });

  final List<FeedFilterChoice> options;
  final String selectedKey;
  final ValueChanged<FeedFilterChoice> onSelected;
  final int collapsedCount;
  final Key Function(String key)? chipKeyBuilder;
  final Key toggleKey;

  @override
  State<DiscoverCollapsibleCategoryChips> createState() =>
      _DiscoverCollapsibleCategoryChipsState();
}

class _DiscoverCollapsibleCategoryChipsState
    extends State<DiscoverCollapsibleCategoryChips> {
  bool _expanded = false;

  List<FeedFilterChoice> _visibleOptions() {
    if (_expanded || widget.options.length <= widget.collapsedCount) {
      return widget.options;
    }
    final count = widget.collapsedCount < 1 ? 1 : widget.collapsedCount;
    final preview = widget.options.take(count).toList();
    final selectedInPreview = preview.any(
      (option) => option.key == widget.selectedKey,
    );
    if (!selectedInPreview) {
      for (final option in widget.options) {
        if (option.key == widget.selectedKey) {
          preview[preview.length - 1] = option;
          break;
        }
      }
    }
    return preview;
  }

  @override
  Widget build(BuildContext context) {
    final canCollapse = widget.options.length > widget.collapsedCount;
    final visible = _visibleOptions();

    return AnimatedSize(
      duration: NovelMotion.contact,
      curve: NovelMotion.ease,
      alignment: Alignment.topLeft,
      child: Wrap(
        spacing: 7,
        runSpacing: 7,
        children: [
          for (final option in visible)
            DiscoverFilterChip(
              key: widget.chipKeyBuilder?.call(option.key),
              dense: true,
              label: option.title,
              selected: widget.selectedKey == option.key,
              onTap: () => widget.onSelected(option),
            ),
          if (canCollapse)
            DiscoverFilterChip(
              key: widget.toggleKey,
              dense: true,
              label: _expanded ? '收起' : '展开',
              leadingIcon: _expanded
                  ? CupertinoIcons.chevron_up
                  : CupertinoIcons.chevron_down,
              selected: false,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
        ],
      ),
    );
  }
}
