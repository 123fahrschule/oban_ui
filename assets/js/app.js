// ObanUI client bundle.
//
// Ships a small set of hooks plus a self-bootstrapping LiveSocket so the
// dashboard works without any host JS setup. Hosts that prefer to merge
// hooks into their own LiveSocket can read `window.ObanUI.Hooks` instead.

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

// ---------------------------------------------------------------------------
// Theme toggle
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
    this.el.setAttribute(
      "aria-label",
      `Theme: ${stored}. Click to switch.`
    );
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

// ---------------------------------------------------------------------------
// Inline SVG sparkline
// ---------------------------------------------------------------------------

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
    this.el.innerHTML = `<svg viewBox="0 0 ${w} ${h}" preserveAspectRatio="none" width="${w}" height="${h}" role="img" aria-label="Sparkline: ${values.length} points, max ${max}"><polyline fill="none" stroke="currentColor" stroke-width="1.5" points="${points}"/></svg>`;
  }
};

// ---------------------------------------------------------------------------
// Confirm-before-action
// ---------------------------------------------------------------------------

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

// indeterminate is a JS-only property — there's no HTML attribute for it. We
// drive it from data-state="some" on the checkbox, server-rendered by the
// LiveView. The server still controls the canonical checked state via the
// `checked` attribute; we only set the visual tri-state here.
const Indeterminate = {
  mounted() { this.apply(); },
  updated() { this.apply(); },
  apply() {
    this.el.indeterminate = this.el.dataset.state === "some";
  }
};

// ---------------------------------------------------------------------------
// Focus-trap for the job detail drawer.
//
// Mounts on the <aside class="oban-ui-drawer">. While the drawer is open:
//   * focuses the first focusable element on mount
//   * cycles Tab/Shift+Tab inside the drawer
//   * closes on Escape (fires the same phx-click="close_detail" event the
//     close button uses)
// ---------------------------------------------------------------------------

const FOCUSABLE =
  "a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex='-1'])";

const DrawerFocusTrap = {
  mounted() {
    this._previouslyFocused = document.activeElement;
    this._keydownHandler = (e) => this.handleKey(e);
    this.el.addEventListener("keydown", this._keydownHandler);
    requestAnimationFrame(() => this.focusFirst());
  },
  destroyed() {
    if (this._keydownHandler) {
      this.el.removeEventListener("keydown", this._keydownHandler);
    }
    if (this._previouslyFocused && this._previouslyFocused.focus) {
      this._previouslyFocused.focus();
    }
  },
  handleKey(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      this.pushEvent("close_detail", {});
      return;
    }
    if (e.key !== "Tab") return;

    const focusables = Array.from(this.el.querySelectorAll(FOCUSABLE)).filter(
      (el) => el.offsetParent !== null
    );
    if (focusables.length === 0) return;

    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    const active = document.activeElement;

    if (e.shiftKey && active === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && active === last) {
      e.preventDefault();
      first.focus();
    }
  },
  focusFirst() {
    const focusables = this.el.querySelectorAll(FOCUSABLE);
    if (focusables.length > 0) focusables[0].focus();
  }
};

// ---------------------------------------------------------------------------
// Global keyboard shortcuts
//   "/"  focuses the first filter input on the page
//   "?"  toggles a help overlay (if present)
//   "g j/q/c/d" go-to navigation (jobs/queues/crons/dashboard)
// ---------------------------------------------------------------------------

const KeyboardShortcuts = {
  mounted() {
    this._gPressed = false;
    this._gTimer = null;
    this._keydownHandler = (e) => this.handleKey(e);
    document.addEventListener("keydown", this._keydownHandler);
  },
  destroyed() {
    document.removeEventListener("keydown", this._keydownHandler);
    if (this._gTimer) clearTimeout(this._gTimer);
  },
  handleKey(e) {
    // Ignore when typing into a form control
    const target = e.target;
    const tag = (target && target.tagName) || "";
    if (
      tag === "INPUT" ||
      tag === "TEXTAREA" ||
      tag === "SELECT" ||
      (target && target.isContentEditable)
    ) {
      return;
    }

    if (this._gPressed) {
      const base = this.el.dataset.basePath || "/oban";
      switch (e.key) {
        case "d": case "h":
          window.location.assign(base + "/");
          break;
        case "j":
          window.location.assign(base + "/jobs");
          break;
        case "q":
          window.location.assign(base + "/queues");
          break;
        case "c":
          window.location.assign(base + "/crons");
          break;
      }
      this._gPressed = false;
      if (this._gTimer) clearTimeout(this._gTimer);
      return;
    }

    if (e.key === "/") {
      const first = document.querySelector(
        "form input:not([type=hidden]):not([disabled])"
      );
      if (first) {
        e.preventDefault();
        first.focus();
      }
    } else if (e.key === "g") {
      this._gPressed = true;
      this._gTimer = setTimeout(() => (this._gPressed = false), 1200);
    } else if (e.key === "Escape") {
      const closeBtn = document.querySelector(
        '[phx-click="close_detail"], [aria-label="Close"]'
      );
      if (closeBtn) closeBtn.click();
    }
  }
};

const Hooks = {
  ThemeToggle,
  Sparkline,
  ConfirmAction,
  DrawerFocusTrap,
  KeyboardShortcuts,
  Indeterminate
};

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
  if (window.ObanUI && window.ObanUI.skipAutoStart) return;

  const liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: { _csrf_token: token },
    hooks: Hooks
  });

  // LiveView's built-in phx-disconnected class lives on individual LV roots,
  // not on <html>. To drive the page-level connectivity banner we toggle the
  // same class on <html> ourselves based on raw socket lifecycle events.
  liveSocket.socket.onError(() => markDisconnected(true));
  liveSocket.socket.onClose(() => markDisconnected(true));
  liveSocket.socket.onOpen(() => markDisconnected(false));

  liveSocket.connect();

  window.ObanUI = window.ObanUI || {};
  window.ObanUI.liveSocket = liveSocket;
  window.ObanUI.Hooks = Hooks;
}

function markDisconnected(yes) {
  document.documentElement.classList.toggle("phx-disconnected", yes);
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", start);
} else {
  start();
}

export { Hooks };
