// Tailwind config used to build the pre-compiled CSS shipped in priv/static.
// Hosts do not need Tailwind installed.

const plugin = require("tailwindcss/plugin");

module.exports = {
  darkMode: ["selector", '[data-theme="dark"]'],
  content: [
    "./js/**/*.js",
    "../lib/oban_ui/**/*.ex",
    "../lib/oban_ui/**/*.heex"
  ],
  theme: {
    extend: {
      colors: {
        // Library namespace so host Tailwind themes don't collide.
        oban: {
          50: "#f4f7fb",
          100: "#e9eef6",
          200: "#cddbeb",
          300: "#a1bbd9",
          400: "#6f97c4",
          500: "#4d79ae",
          600: "#3a6093",
          700: "#304e77",
          800: "#2b4364",
          900: "#283a55",
          950: "#1b2538"
        },
        state: {
          available: "#3b82f6",
          executing: "#10b981",
          scheduled: "#a78bfa",
          retryable: "#f59e0b",
          completed: "#22c55e",
          cancelled: "#9ca3af",
          discarded: "#ef4444"
        }
      },
      fontFamily: {
        mono: ["ui-monospace", "SFMono-Regular", "Menlo", "monospace"]
      }
    }
  },
  plugins: [
    plugin(function ({ addVariant }) {
      addVariant("phx-no-feedback", [
        ".phx-no-feedback&",
        ".phx-no-feedback &"
      ]);
      addVariant("phx-click-loading", [
        ".phx-click-loading&",
        ".phx-click-loading &"
      ]);
      addVariant("phx-submit-loading", [
        ".phx-submit-loading&",
        ".phx-submit-loading &"
      ]);
      addVariant("phx-change-loading", [
        ".phx-change-loading&",
        ".phx-change-loading &"
      ]);
    })
  ]
};
