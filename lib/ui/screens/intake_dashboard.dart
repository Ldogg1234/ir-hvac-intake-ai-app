import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../style/precision_theme.dart';

class IntakeDashboard extends StatelessWidget {
  const IntakeDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: PrecisionTheme.background,
      appBar: AppBar(
        toolbarHeight: 80,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'IRHVAC COMMAND CENTER',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: PrecisionTheme.pureWhite,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'HEATING & COOLING SPECIALISTS',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: PrecisionTheme.surfaceVeryDark,
                    letterSpacing: 2.0,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
        centerTitle: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Responsive configuration mapping 2 columns for Techs (<600px), 4 cols for Admins (>800px)
          final isDesktop = constraints.maxWidth > 800;
          final crossAxisCount = isDesktop ? 4 : 2; 

          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: StaggeredGrid.count(
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 16.0,
                crossAxisSpacing: 16.0,
                children: [
                  // 2x2 Hero Block - 'Emergency Dispatch'
                  StaggeredGridTile.count(
                    crossAxisCellCount: 2,
                    mainAxisCellCount: 2,
                    child: ActiveBentoModule(
                      title: 'Emergency Dispatch', 
                      icon: Icons.bolt,
                      isActive: true,
                      isHero: true,
                    ),
                  ),
                  
                  // 1x1 'System Diagnostics'
                  const StaggeredGridTile.count(
                    crossAxisCellCount: 1,
                    mainAxisCellCount: 1,
                    child: ActiveBentoModule(
                      title: 'System Diagnostics', 
                      icon: Icons.troubleshoot,
                    ),
                  ),
                  
                  // 1x1 'Active Tech Tracking'
                  const StaggeredGridTile.count(
                    crossAxisCellCount: 1,
                    mainAxisCellCount: 1,
                    child: ActiveBentoModule(
                      title: 'Active Tech Tracking', 
                      icon: Icons.radar,
                      isActive: true, 
                    ),
                  ),
                  
                  // 2x1 'Equipment Specs' (Spans 2 columns if space allows)
                  StaggeredGridTile.count(
                    crossAxisCellCount: isDesktop ? 2 : crossAxisCount,
                    mainAxisCellCount: 1,
                    child: const ActiveBentoModule(
                      title: 'Equipment Specs', 
                      icon: Icons.settings_applications,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class ActiveBentoModule extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isActive;
  final bool isHero;

  const ActiveBentoModule({
    super.key, 
    required this.title, 
    required this.icon,
    this.isActive = false,
    this.isHero = false,
  });

  @override
  Widget build(BuildContext context) {
    // Hardcoding active visual state for now
    final actuallyActive = isActive;

    return Container(
      decoration: BoxDecoration(
        color: PrecisionTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        // 15% Ghost borders by default as requested
        border: Border.all(color: PrecisionTheme.ghostBorder, width: 1),
        boxShadow: actuallyActive ? [
          // Inner glow for active modules
          BoxShadow(
            color: PrecisionTheme.primaryCyan.withOpacity(0.2),
            blurRadius: 15,
            blurStyle: BlurStyle.inner, 
          )
        ] : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            debugPrint('Tapped $title module');
          },
          child: Padding(
            padding: EdgeInsets.all(isHero ? 32.0 : 24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: actuallyActive ? PrecisionTheme.primaryCyan : PrecisionTheme.surfaceContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: actuallyActive ? PrecisionTheme.background : PrecisionTheme.pureWhite,
              size: isHero ? 48 : 32,
            ),
          ),
          SizedBox(height: isHero ? 32 : 16),
          Expanded(
            child: Text(
              title,
              style: (isHero ? Theme.of(context).textTheme.headlineMedium : Theme.of(context).textTheme.titleLarge)?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          if (actuallyActive)
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: PrecisionTheme.primaryCyan,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'SYNCED',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PrecisionTheme.primaryCyan,
                        letterSpacing: 2.0,
                      ),
                ),
              ],
            )
        ],
      ),
          ),
        ),
      ),
    );
  }
}
