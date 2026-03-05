# UI/UX Standard for IMR HVAC Tech Report

This document defines the visual language and layout principles for the IMR HVAC Tech Report application. All new UI components and screens must adhere to these standards to ensure a premium, professional, and consistent technician experience.

## Official Brand Palette
- **Primary (Sky Blue)**: `#3498DB` - A light and airy blue matching the website logo. Use for headers, icons, and status indicators.
- **Action Orange**: `#E67E22` - A high-contrast orange used strictly for buttons, 'Urgent' flags, and the 'Finalize Invoice' action.
- **Backgrounds**: 
    - `#FFFFFF` - Clean white background for all Bento cards.
    - `#F4F7F6` - Soft gray for the main scaffold background.

## Design Style: Bento Box Layout
- **Grouping**: Organize related data into distinct, rounded containers (cards) to maintain high data density.
- **Background**: Use pure white (`#FFFFFF`) for card backgrounds.
- **Spacing**: Use a consistent gap (12px) between bento cells.
- **Rounding**: Apply `12px` corner radius to all containers.
- **Active Card**: Add a `2px` Sky Blue (`#3498DB`) left-border to the active/current job card to make it visually stand out.
- **Responsive Grid**: Use `LayoutBuilder` to detect viewport width. On tablets (>600px), pair cards side-by-side in rows. On phones, stack cards vertically.
- **Legibility**: The **White-on-Light-Grey** layout is mandatory to ensure the interface is clean, modern, and highly legible for technicians working in low-light environments (e.g., dark basements).
- **CTA Alignment**: Ensure all primary action buttons use the `#E67E22` orange accent.

## Visual Effects: Depth & Clarity
- **Shadows**: Use soft, subtle elevation shadows (e.g., blur 10px, spread 2px, 5% black) to define cards against the light grey background.
- **Borders**: Avoid heavy glassmorphism. Use thin, high-contrast borders or shadows to maintain the "light and airy" feel.

## Typography
- **Families**: Use `Inter` or `Roboto` with clear weight differences between headers and body text.
- **Hierarchy**:
    - **Headers**: Bold or Extra-Bold weight, using the Primary Blue (`#3498DB`).
    - **Labels**: Semi-Bold weight, using dark slate or gray for contrast.
    - **Body**: Regular weight, high-contrast dark text for maximum readability.
- **Contrast**: Ensure high readability by following WCAG accessibility standards for text-on-white.
