# Motion & Interaction Design Standards

These standards ensure the application feels responsive, tactile, and premium through deliberate motion and feedback.

## Tactile Feedback
- **Haptics**: Always trigger `HapticFeedback.lightImpact` on every primary action (e.g., "Generate Report", "Add Photo", "Save").
- **Visual Press**: Use subtle scale-down effects (e.g., `0.98x`) on button press to reinforce the tactile feel.

## Loading States
- **Shimmer Effects**: Never show a blank screen or a simple static spinner for large data areas. Use "ghost loaders" (shimmering skeletons) that mimic the layout of the final report while the AI is generating content.
- **Micro-animations**: Use subtle pulsing or rotating icons within buttons to indicate background activity without blocking the entire UI if possible.

## Transitions
- **Hero Animations**: All technical evidence (photos of furnaces, AC units, etc.) must use `Hero` tags. Clicking a thumbnail should smoothly expand and transition the photo into the final report view or a detailed inspection view.
- **Staggered Entry**: Lists and Bento Box cards should use staggered fade-in/slide-up animations to avoid a jarring "pop-in" effect.
