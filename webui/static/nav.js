// Боковое меню: подсветка текущего раздела, заголовок в верхней полосе и
// выдвижное меню на узких экранах (кнопка-бургер).
(function () {
  var root = document.documentElement;
  var path = location.pathname.replace(/\/+$/, "") || "/";
  var crumb = document.getElementById("topbar-section");

  document.querySelectorAll(".sidebar nav a").forEach(function (a) {
    var href = a.getAttribute("href");
    var on = href === "/" ? path === "/" : path === href || path.indexOf(href + "/") === 0;
    if (on) {
      a.classList.add("active");
      a.setAttribute("aria-current", "page");
      if (crumb) crumb.textContent = a.getAttribute("data-title") || a.textContent.trim();
    }
  });

  var burger = document.querySelector(".nav-burger");
  var sidebar = document.getElementById("sidebar");

  function setOpen(open) {
    root.classList.toggle("nav-open", open);
    if (burger) burger.setAttribute("aria-expanded", open ? "true" : "false");
    if (open && sidebar) {
      var first = sidebar.querySelector("nav a");
      if (first) first.focus();
    }
  }

  if (burger) {
    burger.addEventListener("click", function () {
      setOpen(!root.classList.contains("nav-open"));
    });
  }
  document.addEventListener("click", function (ev) {
    if (!root.classList.contains("nav-open")) return;
    var t = ev.target;
    if (t.closest && (t.closest(".sidebar-backdrop") || t.closest(".sidebar nav a"))) setOpen(false);
  });
  document.addEventListener("keydown", function (ev) {
    if (ev.key === "Escape" && root.classList.contains("nav-open")) {
      setOpen(false);
      if (burger) burger.focus();
    }
  });
  // Перешли на широкий экран — выдвижное меню закрываем.
  if (window.matchMedia) {
    var wide = window.matchMedia("(min-width: 961px)");
    var onWide = function () {
      if (wide.matches) setOpen(false);
    };
    if (wide.addEventListener) wide.addEventListener("change", onWide);
    else if (wide.addListener) wide.addListener(onWide);
  }
})();
