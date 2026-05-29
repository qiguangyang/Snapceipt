import Foundation

/// Raw 24×24-grid SVG path data ported verbatim from theme.jsx ICONS.
/// Core set used by the app shell, profiles, and auth flows. The remaining
/// theme.jsx glyphs are added here identically (same `d` strings, no other change).
enum Icons {
    static let paths: [String: String] = [
        "home": "M3 10.6 12 4l9 6.6M5.5 9.2V19a1 1 0 0 0 1 1H10v-5h4v5h3.5a1 1 0 0 0 1-1V9.2",
        "receipt": "M6 3h12v18l-2.2-1.4L13.6 21 12 19.6 10.4 21 8.2 19.6 6 21V3ZM9 8h6M9 12h6M9 16h3",
        "chart": "M4 20V10M10 20V4M16 20v-7M22 20H2",
        "user": "M12 12.6a4.1 4.1 0 1 0 0-8.2 4.1 4.1 0 0 0 0 8.2ZM4.6 20a7.5 7.5 0 0 1 14.8 0",
        "camera": "M3.5 8.5A2 2 0 0 1 5.5 6.5h1.7l1-1.7a1 1 0 0 1 .9-.5h5.8a1 1 0 0 1 .9.5l1 1.7h1.7a2 2 0 0 1 2 2v8.5a2 2 0 0 1-2 2h-15a2 2 0 0 1-2-2V8.5ZM12 17a3.7 3.7 0 1 0 0-7.4 3.7 3.7 0 0 0 0 7.4Z",
        "plus": "M12 5v14M5 12h14",
        "chevR": "M9 6l6 6-6 6",
        "chevD": "M6 9l6 6 6-6",
        "arrowLeft": "M19 12H5M11 6l-6 6 6 6",
        "check": "M5 12.5 10 17.5 19.5 7",
        "close": "M6 6l12 12M18 6 6 18",
        "bell": "M6.5 10a5.5 5.5 0 0 1 11 0c0 5 2 6.5 2 6.5H4.5s2-1.5 2-6.5ZM9.5 19.5a2.6 2.6 0 0 0 5 0",
        "sparkles": "M12 3l1.7 4.6L18.3 9.3 13.7 11 12 15.6 10.3 11 5.7 9.3 10.3 7.6 12 3ZM18.5 14l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8.8-2.2Z",
        "gear": "M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4ZM19.4 12c0-.5-.05-1-.13-1.46l1.7-1.32-1.9-3.3-2 .8a7.5 7.5 0 0 0-2.5-1.45L14.2 3h-4.4l-.3 2.27A7.5 7.5 0 0 0 7 6.72l-2-.8-1.9 3.3 1.7 1.32a7.7 7.7 0 0 0 0 2.92l-1.7 1.32 1.9 3.3 2-.8a7.5 7.5 0 0 0 2.5 1.45L9.8 21h4.4l.3-2.27a7.5 7.5 0 0 0 2.5-1.45l2 .8 1.9-3.3-1.7-1.32c.08-.46.13-.96.13-1.46Z",
        "wallet": "M4 7.5A1.5 1.5 0 0 1 5.5 6H18a1 1 0 0 1 1 1v1.5M4 7.5V18a1 1 0 0 0 1 1h13a1 1 0 0 0 1-1v-3.5M4 7.5h14.5M16 11.5h3.5v3H16a1.5 1.5 0 0 1 0-3Z",
        "building": "M5 20V5a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v15M14 20V9h4a1 1 0 0 1 1 1v10M4 20h16M8 8h3M8 12h3M8 16h3",
        "star": "M12 3.5l2.6 5.3 5.9.86-4.25 4.14 1 5.85L12 17.1l-5.25 2.6 1-5.85L3.5 9.66l5.9-.86L12 3.5Z",
    ]
    // ADD THE REMAINING theme.jsx ICONS HERE the same way (arrowUp, arrowDown, arrowRight,
    // car, wfh, search, flash, image, share, tag, calendar, edit, filter, dots, cup, cart,
    // fuel, film, bank, doc, heart, trash, pencil, link, shield, lock, pin, clock, swap,
    // scan, download, info, logout, phone) — copy each `d` string verbatim from theme.jsx.
}
