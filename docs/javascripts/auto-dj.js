/**
 * Copyright 2026 BitWise Media Group Ltd
 * SPDX-License-Identifier: MIT
 */

/* auto-dj docs: the landing's live deck and command rows (overrides/home.html).
 *
 * Runs on every page load through Material's document$ (instant navigation swaps
 * the page without reloading scripts), tearing down the previous page's timers and
 * observers first.
 *
 * - Command rows (.ad-cmd code) are split into shell words so they wrap only between
 *   arguments; the last word on each wrapped line gets data-wrap, and extra.css
 *   appends the shell's " \" continuation. The copy button copies the one-line command.
 * - The deck: a playhead runs along the "On a real track" timeline and strikes each
 *   hot cue's pad as it passes, showing that pad on the deck's screen. Striking a pad
 *   by hand shows that one until the playhead reaches the next cue. Reduced motion
 *   starts it paused.
 */
(function () {
  "use strict";

  var LOOP_MS = 24000;
  var TICK_MS = 50;
  var cleanups = [];

  // A command's shell words, quoted arguments kept whole.
  function words(cmd) {
    return cmd.match(/(?:"[^"]*"|'[^']*'|\S)+/g) || [];
  }

  function wrapCommand(code) {
    if (!code.dataset.cmd) {
      var cmd = code.textContent.trim();
      code.dataset.cmd = cmd;
      code.textContent = "";
      words(cmd).forEach(function (w) {
        var span = document.createElement("span");
        span.className = "ad-arg";
        span.textContent = w;
        code.appendChild(span);
      });
    }
    var mark = function () {
      var spans = code.children;
      for (var i = 0; i < spans.length; i++) {
        var next = spans[i + 1];
        spans[i].toggleAttribute("data-wrap", !!next && next.offsetTop > spans[i].offsetTop);
      }
    };
    mark();
    if (document.fonts) document.fonts.ready.then(mark);
    var ro = new ResizeObserver(mark);
    ro.observe(code);
    cleanups.push(function () {
      ro.disconnect();
    });
  }

  function startDeck(root) {
    var pads = root.querySelectorAll("[data-pad]");
    var readouts = root.querySelectorAll("[data-readout]");
    var head = root.querySelector(".ad-tl__head");
    var button = root.querySelector("[data-ad-play]");
    var cues = Array.prototype.map.call(root.querySelectorAll("[data-cue]"), function (el) {
      return { k: el.dataset.cue, at: parseFloat(el.style.left) };
    });
    var pos = 10;
    var timer = 0;
    var hitTimer = 0;

    function show(k) {
      readouts.forEach(function (r) {
        var on = r.dataset.readout === k;
        r.classList.toggle("is-shown", on);
        r.setAttribute("aria-hidden", on ? "false" : "true");
      });
      pads.forEach(function (p) {
        p.setAttribute("aria-pressed", p.dataset.pad === k ? "true" : "false");
      });
    }

    function strike(k) {
      show(k);
      pads.forEach(function (p) {
        p.classList.toggle("is-hit", p.dataset.pad === k);
      });
      clearTimeout(hitTimer);
      hitTimer = setTimeout(function () {
        pads.forEach(function (p) {
          p.classList.remove("is-hit");
        });
      }, 240);
    }

    function tick() {
      var step = 100 / (LOOP_MS / TICK_MS);
      var next = pos + step >= 100 ? 0 : pos + step;
      cues.forEach(function (c) {
        if (pos < c.at && next >= c.at) strike(c.k);
      });
      pos = next;
      if (head) head.style.left = pos + "%";
    }

    function play(on) {
      clearInterval(timer);
      timer = on ? setInterval(tick, TICK_MS) : 0;
      if (button) button.textContent = on ? "Pause" : "Play";
    }

    pads.forEach(function (p) {
      p.addEventListener("click", function () {
        strike(p.dataset.pad);
      });
    });
    if (button) {
      button.addEventListener("click", function () {
        play(!timer);
      });
    }
    play(!matchMedia("(prefers-reduced-motion: reduce)").matches);
    cleanups.push(function () {
      clearInterval(timer);
      clearTimeout(hitTimer);
    });
  }

  function setup() {
    cleanups.forEach(function (fn) {
      fn();
    });
    cleanups = [];
    document.querySelectorAll(".ad-cmd code").forEach(wrapCommand);
    var root = document.querySelector(".ad");
    if (root && root.querySelector("[data-pad]")) startDeck(root);
  }

  // Copy buttons on the command rows. Delegated once on document, so it survives
  // instant navigation; scoped to .ad-cmd so it never touches Material's own code-block
  // buttons. Reuses Material's snackbar so the feedback matches the native button.
  document.addEventListener("click", function (e) {
    var btn = e.target.closest(".ad-cmd .md-code__button");
    if (!btn) return;
    var code = btn.closest(".ad-cmd").querySelector("code");
    if (!code) return;
    navigator.clipboard.writeText(code.dataset.cmd || code.textContent.trim()).then(function () {
      btn.focus();
      var dialog = document.querySelector("[data-md-component=dialog]");
      if (!dialog) return;
      (dialog.querySelector(".md-dialog__inner") || dialog).textContent = "Copied to clipboard";
      dialog.classList.add("md-dialog--active");
      clearTimeout(dialog.adResetTimer);
      dialog.adResetTimer = setTimeout(function () {
        dialog.classList.remove("md-dialog--active");
      }, 2000);
    });
  });

  if (window.document$) window.document$.subscribe(setup);
  else document.addEventListener("DOMContentLoaded", setup);
})();
