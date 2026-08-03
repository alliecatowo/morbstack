// Morbstack marketing site — small progressive-enhancement script.
// Everything here is optional: every page's content is fully readable
// and usable with this file absent (theme falls back to
// prefers-color-scheme, copy buttons simply don't appear/act, and the
// docs TOC is just a list of anchor links).

(function () {
  "use strict";

  /* ---------------------------------------------------------------
     Theme toggle, persisted in localStorage under "morbstack-theme".
  --------------------------------------------------------------- */
  var STORAGE_KEY = "morbstack-theme";

  function getStoredTheme() {
    try {
      return localStorage.getItem(STORAGE_KEY);
    } catch (err) {
      return null;
    }
  }

  function setStoredTheme(theme) {
    try {
      if (theme) {
        localStorage.setItem(STORAGE_KEY, theme);
      } else {
        localStorage.removeItem(STORAGE_KEY);
      }
    } catch (err) {
      /* localStorage unavailable (private mode, file:// restrictions in
         some browsers) — theme still works for the session via the
         data-theme attribute, it just won't persist. */
    }
  }

  function applyTheme(theme) {
    var root = document.documentElement;
    if (theme === "dark" || theme === "light") {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
    var toggle = document.querySelector(".theme-toggle");
    if (toggle) {
      var isDark =
        theme === "dark" ||
        (!theme && window.matchMedia("(prefers-color-scheme: dark)").matches);
      toggle.setAttribute("aria-pressed", String(isDark));
    }
  }

  // Apply immediately (before paint-ish) so there's no flash.
  applyTheme(getStoredTheme());

  document.addEventListener("DOMContentLoaded", function () {
    var toggle = document.querySelector(".theme-toggle");
    if (toggle) {
      toggle.addEventListener("click", function () {
        var current =
          getStoredTheme() ||
          (window.matchMedia("(prefers-color-scheme: dark)").matches
            ? "dark"
            : "light");
        var next = current === "dark" ? "light" : "dark";
        setStoredTheme(next);
        applyTheme(next);
      });
    }

    /* ---------------------------------------------------------------
       Copy-to-clipboard buttons on command blocks.
       Markup: <div class="code-block"><pre>...</pre>
                 <button class="copy-btn" type="button">Copy</button></div>
    --------------------------------------------------------------- */
    var copyButtons = document.querySelectorAll(".copy-btn[data-copy-target]");
    copyButtons.forEach(function (btn) {
      btn.addEventListener("click", function () {
        var targetId = btn.getAttribute("data-copy-target");
        var target = targetId ? document.getElementById(targetId) : null;
        if (!target) return;
        var text = target.innerText || target.textContent || "";
        if (!navigator.clipboard || !navigator.clipboard.writeText) {
          return; // fail silently — the command is still selectable/readable text
        }
        navigator.clipboard.writeText(text).then(
          function () {
            var original = btn.textContent;
            btn.textContent = "Copied";
            btn.setAttribute("data-copied", "true");
            setTimeout(function () {
              btn.textContent = original;
              btn.removeAttribute("data-copied");
            }, 1600);
          },
          function () {
            /* clipboard write denied — fail silently, the text remains
               selectable by hand */
          }
        );
      });
    });

    /* ---------------------------------------------------------------
       Docs page: scrollspy for the sticky table of contents.
    --------------------------------------------------------------- */
    var tocLinks = document.querySelectorAll(".docs-toc a[href^='#']");
    if (tocLinks.length) {
      var sections = [];
      tocLinks.forEach(function (link) {
        var id = link.getAttribute("href").slice(1);
        var section = document.getElementById(id);
        if (section) sections.push({ link: link, section: section });
      });

      var setActive = function (id) {
        tocLinks.forEach(function (link) {
          if (link.getAttribute("href") === "#" + id) {
            link.classList.add("active");
          } else {
            link.classList.remove("active");
          }
        });
      };

      if ("IntersectionObserver" in window && sections.length) {
        var observer = new IntersectionObserver(
          function (entries) {
            entries.forEach(function (entry) {
              if (entry.isIntersecting) {
                setActive(entry.target.id);
              }
            });
          },
          { rootMargin: "-96px 0px -70% 0px", threshold: 0 }
        );
        sections.forEach(function (item) {
          observer.observe(item.section);
        });
      }
    }
  });
})();
