// ObanUI client bundle.
//
// Ships a small set of hooks plus a self-bootstrapping LiveSocket so the
// dashboard works without any host JS setup. Hosts that prefer to merge
// hooks into their own LiveSocket can read `window.ObanUI.Hooks` instead.

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

const ThemeToggle = {
  mounted() {
    this.apply();
    this.el.addEventListener("click", () => {
      const current = localStorage.getItem("oban_ui_theme") || "system";
      const next = nextTheme(current);
      localStorage.setItem("oban_ui_theme", next);
      this.apply();
    });
    this._media = window.matchMedia("(prefers-color-scheme: dark)");
    this._listener = () => this.apply();
    this._media.addEventListener("change", this._listener);
  },
  destroyed() {
    if (this._media) this._media.removeEventListener("change", this._listener);
  },
  apply() {
    const stored = localStorage.getItem("oban_ui_theme") || "system";
    let effective = stored;
    if (stored === "system") {
      effective = window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light";
    }
    document.documentElement.dataset.theme = effective;
    this.el.dataset.theme = stored;
  }
};

function nextTheme(current) {
  switch (current) {
    case "light":
      return "dark";
    case "dark":
      return "system";
    default:
      return "light";
  }
}

const Sparkline = {
  mounted() {
    this.draw();
  },
  updated() {
    this.draw();
  },
  draw() {
    const raw = this.el.dataset.series || "";
    const values = raw
      .split(",")
      .map(Number)
      .filter((v) => !isNaN(v));
    if (values.length === 0) return;
    const w = this.el.clientWidth || 120;
    const h = this.el.clientHeight || 32;
    const max = Math.max(1, ...values);
    const step = w / Math.max(1, values.length - 1);
    const points = values
      .map((v, i) => `${(i * step).toFixed(1)},${(h - (v / max) * h).toFixed(1)}`)
      .join(" ");
    this.el.innerHTML = `<svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" width="${w}" height="${h}"><polyline fill="none" stroke="currentColor" stroke-width="1.5" points="${points}"/></svg>`;
  }
};

const ConfirmAction = {
  mounted() {
    this.el.addEventListener("click", (e) => {
      const message = this.el.dataset.confirm;
      if (message && !window.confirm(message)) {
        e.preventDefault();
        e.stopImmediatePropagation();
      }
    });
  }
};

const Hooks = { ThemeToggle, Sparkline, ConfirmAction };

// ---------------------------------------------------------------------------
// LiveSocket bootstrap
// ---------------------------------------------------------------------------

function csrfToken() {
  const meta = document.querySelector("meta[name='csrf-token']");
  return meta ? meta.getAttribute("content") : null;
}

function start() {
  const token = csrfToken();
  if (!token) {
    console.warn("ObanUI: csrf-token meta not found; LiveSocket not started");
    return;
  }

  // Allow hosts to opt out by setting `window.ObanUI.skipAutoStart = true`
  // before our script runs.
  if (window.ObanUI && window.ObanUI.skipAutoStart) return;

  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: token },
    hooks: Hooks
  });

  liveSocket.connect();

  window.ObanUI = window.ObanUI || {};
  window.ObanUI.liveSocket = liveSocket;
  window.ObanUI.Hooks = Hooks;
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}

export { Hooks };
