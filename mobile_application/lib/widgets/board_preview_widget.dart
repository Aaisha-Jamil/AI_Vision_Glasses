import 'package:flutter/material.dart';
import '../models/board_image_item.dart';

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

    Widget visualImage = Container(
      height: compact ? 140 : 210,
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E282D) : const Color(0xFF2C3E50),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.teal.withValues(alpha: 0.5),
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
          // Background subtle grid/chalk effect
          Positioned.fill(
            child: CustomPaint(
              painter: _ChalkboardGridPainter(),
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
                        color: Colors.teal.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.camera_alt, color: Colors.tealAccent, size: 14),
                          SizedBox(width: 4),
                          Text(
                            'AI GLASSES CAPTURE',
                            style: TextStyle(
                              color: Colors.tealAccent,
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
                // Board visual diagram
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
                            color: Colors.amberAccent,
                            fontFamily: 'monospace',
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
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

    Widget transcriptSide = Container(
      height: compact ? 140 : 210,
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1B2428) : const Color(0xFFF4F7F9),
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
              const Icon(Icons.text_snippet_outlined, color: Colors.teal, size: 18),
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
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '98% match',
                  style: TextStyle(color: Colors.green, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const Divider(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.option == BoardImageOption.imageAsIs)
          visualImage
        else if (item.option == BoardImageOption.ocr)
          transcriptSide
        else
          // Both: Show image with transcripts at side (responsive row/column)
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 580) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: visualImage),
                    const SizedBox(width: 14),
                    Expanded(child: transcriptSide),
                  ],
                );
              } else {
                return Column(
                  children: [
                    visualImage,
                    const SizedBox(height: 12),
                    transcriptSide,
                  ],
                );
              }
            },
          ),
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
              color: isSelected ? theme.colorScheme.primary : Colors.grey,
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
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
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
                  color: isSelected ? theme.colorScheme.primary : Colors.grey,
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
