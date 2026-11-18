import 'package:flutter/material.dart';
import '../models/board_image_item.dart';
import '../theme/app_theme.dart';
import 'image_loader.dart';

class BoardPreviewWidget extends StatelessWidget {
  const BoardPreviewWidget({
    super.key,
    required this.item,
    this.showOptionsSelector = false,
    this.onOptionChanged,
    this.compact = false,
  });

  final CapturedImageItem item;
  final bool showOptionsSelector;
  final ValueChanged<BoardImageOption>? onOptionChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    Widget content;
    if (item.option == BoardImageOption.imageAsIs) {
      content = _buildVisualImage(context, isDark);
    } else if (item.option == BoardImageOption.ocr) {
      content = _buildTranscriptSide(context, isDark, theme);
    } else {
      content = LayoutBuilder(
        builder: (ctx, constraints) {
          if (constraints.maxWidth > 580) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildVisualImage(ctx, isDark)),
                const SizedBox(width: 14),
                Expanded(child: _buildTranscriptSide(ctx, isDark, theme)),
              ],
            );
          } else {
            return Column(
              children: [
                _buildVisualImage(ctx, isDark),
                const SizedBox(height: 12),
                _buildTranscriptSide(ctx, isDark, theme),
              ],
            );
          }
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        if (showOptionsSelector) ...[
          const SizedBox(height: 16),
          const Text(
            'Select Display / Save Option:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
          const SizedBox(height: 8),
          _buildOptionSelector(context),
        ],
      ],
    );
  }

  Widget _buildVisualImage(BuildContext context, bool isDark) {
    final theme = Theme.of(context);
    final hasRemote = item.remoteImageUrl != null && item.remoteImageUrl!.isNotEmpty;
    final hasLocal = localImageExists(item.localImagePath);
    final hasRealImage = hasRemote || hasLocal;

    return Container(
      height: compact ? 140 : 210,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.boardDark : AppTheme.deepForest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (hasRemote)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Image.network(
                  item.remoteImageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => CustomPaint(painter: _ChalkboardGridPainter()),
                ),
              ),
            )
          else if (hasLocal && loadLocalImage(item.localImagePath) != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: loadLocalImage(item.localImagePath)!,
              ),
            )
          else
            Positioned.fill(
              child: CustomPaint(
                painter: _ChalkboardGridPainter(),
              ),
            ),
          // Subtle gradient overlay when displaying real photo
          if (hasRealImage)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.75),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.camera_alt, color: isDark ? AppTheme.softSage : AppTheme.warmCream, size: 14),
                          const SizedBox(width: 4),
                          Text(
                            'AI GLASSES CAPTURE',
                            style: TextStyle(
                              color: isDark ? AppTheme.softSage : AppTheme.warmCream,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      '1080p • YOLOv8 Clean',
                      style: TextStyle(color: Colors.white70, fontSize: 10),
                    ),
                  ],
                ),
                const Spacer(),
                // Real photo badge or chalkboard diagram
                if (!hasRealImage)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDiagramBox('Audio/Camera'),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.arrow_forward, color: Colors.white70, size: 14),
                              ),
                              _buildDiagramBox('YOLO Blur'),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Icon(Icons.arrow_forward, color: Colors.white70, size: 14),
                              ),
                              _buildDiagramBox('OCR/NLP'),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            r'L_privacy = \lambda \cdot ||I_{blur} - I_{orig}||',
                            style: TextStyle(
                              color: AppTheme.warmSand,
                              fontFamily: 'monospace',
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: (isDark ? AppTheme.softSage : AppTheme.warmSand).withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.shield_outlined, color: isDark ? AppTheme.softSage : AppTheme.warmSand, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            item.peopleDetected > 0
                                ? 'YOLOv8 Shield: ${item.peopleDetected} Person(s) Blurred'
                                : 'YOLOv8 Privacy Shield: Verified Active',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscriptSide(BuildContext context, bool isDark, ThemeData theme) {
    return Container(
      height: compact ? 140 : 210,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.surfaceDark : AppTheme.paleSea,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.text_snippet_outlined, color: theme.colorScheme.primary, size: 18),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Extracted Transcript (OCR)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '98% match',
                  style: TextStyle(color: AppTheme.success, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                item.ocrText,
                style: TextStyle(
                  fontSize: compact ? 11 : 12,
                  height: 1.4,
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDiagramBox(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildOptionSelector(BuildContext context) {
    return Column(
      children: [
        _buildOptionTile(
          context: context,
          option: BoardImageOption.imageAsIs,
          icon: Icons.image_outlined,
          title: 'Image as it is',
          subtitle: 'Store raw board visual only',
        ),
        const SizedBox(height: 6),
        _buildOptionTile(
          context: context,
          option: BoardImageOption.ocr,
          icon: Icons.text_snippet_outlined,
          title: 'OCR',
          subtitle: 'Store extracted text transcript only',
        ),
        const SizedBox(height: 6),
        _buildOptionTile(
          context: context,
          option: BoardImageOption.both,
          icon: Icons.splitscreen,
          title: 'Both (Image + OCR)',
          subtitle: 'Store both board visual and OCR transcripts side-by-side',
        ),
      ],
    );
  }

  Widget _buildOptionTile({
    required BuildContext context,
    required BoardImageOption option,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = item.option == option;
    final theme = Theme.of(context);

    return InkWell(
      onTap: () => onOptionChanged?.call(option),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary.withValues(alpha: 0.12)
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? theme.colorScheme.primary : AppTheme.mutedText,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      fontSize: 14,
                      color: isSelected ? theme.colorScheme.primary : null,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: AppTheme.mutedText),
                  ),
                ],
              ),
            ),
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected ? theme.colorScheme.primary : AppTheme.mutedText,
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChalkboardGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1;

    const spacing = 20.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
