// Переключатель темы: авто (системная) → светлая → тёмная → авто.
// Выбор хранится в localStorage["nanopi-theme"] ("light" | "dark"; нет ключа — авто).
// Тема применяется до отрисовки inline-скриптом в шаблоне "head" (атрибут
// data-theme на <html>); здесь только кнопка и подписи.
(function () {
  var KEY = "nanopi-theme";
  var ORDER = ["auto", "light", "dark"];
  var LABEL = { auto: "авто (как в системе)", light: "светлая", dark: "тёмная" };
  var root = document.documentElement;

  function current() {
    var t = root.getAttribute("data-theme");
    return t === "light" || t === "dark" ? t : "auto";
  }

  function apply(mode) {
    if (mode === "light" || mode === "dark") root.setAttribute("data-theme", mode);
    else root.removeAttribute("data-theme");
    try {
      if (mode === "auto") localStorage.removeItem(KEY);
      else localStorage.setItem(KEY, mode);
    } catch (e) {}
    label();
  }

  function label() {
    var mode = current();
    var next = ORDER[(ORDER.indexOf(mode) + 1) % ORDER.length];
    document.querySelectorAll(".theme-toggle").forEach(function (b) {
      var t = "Тема: " + LABEL[mode] + ". Нажмите — " + LABEL[next];
      b.setAttribute("title", t);
      b.setAttribute("aria-label", t);
      b.setAttribute("data-mode", mode);
    });
  }

  document.addEventListener("click", function (ev) {
    var b = ev.target.closest && ev.target.closest(".theme-toggle");
    if (!b) return;
    apply(ORDER[(ORDER.indexOf(current()) + 1) % ORDER.length]);
  });

  // Выбор в другой вкладке панели.
  window.addEventListener("storage", function (ev) {
    if (ev.key !== KEY) return;
    var v = ev.newValue;
    if (v === "light" || v === "dark") root.setAttribute("data-theme", v);
    else root.removeAttribute("data-theme");
    label();
  });

  label();
  window.nanopiTheme = { get: current, set: apply };
})();
