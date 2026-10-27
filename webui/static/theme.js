// Переключатель темы: светлая ⇄ тёмная.
// Выбор хранится в localStorage["nanopi-theme"] ("light" | "dark") и пишется
// только по нажатию кнопки. Пока выбора нет, тема следует системной
// (prefers-color-scheme), в том числе при её смене на лету.
// Начальную тему ставит inline-скрипт шаблона "head" (атрибут data-theme на
// <html>) до загрузки стилей; здесь — кнопка, подписи и синхронизация.
(function () {
  var KEY = "nanopi-theme";
  var LABEL = { light: "светлая", dark: "тёмная" };
  var root = document.documentElement;
  var mq = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function saved() {
    try {
      var v = localStorage.getItem(KEY);
      return v === "light" || v === "dark" ? v : null;
    } catch (e) {
      return null;
    }
  }

  function system() {
    return mq && mq.matches ? "dark" : "light";
  }

  function current() {
    var t = root.getAttribute("data-theme");
    return t === "light" || t === "dark" ? t : system();
  }

  function show(mode) {
    root.setAttribute("data-theme", mode);
    label();
  }

  // Явный выбор пользователя — сохраняется.
  function apply(mode) {
    if (mode !== "light" && mode !== "dark") return;
    try {
      localStorage.setItem(KEY, mode);
    } catch (e) {}
    show(mode);
  }

  // Сбросить выбор и вернуться к системной теме (для консоли/отладки).
  function reset() {
    try {
      localStorage.removeItem(KEY);
    } catch (e) {}
    show(system());
  }

  function label() {
    var mode = current();
    var next = mode === "dark" ? "light" : "dark";
    var src = saved() ? "" : " (как в системе)";
    document.querySelectorAll(".theme-toggle").forEach(function (b) {
      var t = "Тема: " + LABEL[mode] + src + ". Нажмите — " + LABEL[next];
      b.setAttribute("title", t);
      b.setAttribute("aria-label", t);
      b.setAttribute("data-mode", mode);
      var txt = b.querySelector(".theme-toggle-text");
      if (txt) txt.textContent = mode === "dark" ? "Тёмная тема" : "Светлая тема";
    });
  }

  document.addEventListener("click", function (ev) {
    var b = ev.target.closest && ev.target.closest(".theme-toggle");
    if (!b) return;
    apply(current() === "dark" ? "light" : "dark");
  });

  // Системная тема сменилась: следуем ей, только если выбора нет.
  if (mq) {
    var onSystem = function () {
      if (!saved()) show(system());
    };
    if (mq.addEventListener) mq.addEventListener("change", onSystem);
    else if (mq.addListener) mq.addListener(onSystem);
  }

  // Выбор в другой вкладке панели.
  window.addEventListener("storage", function (ev) {
    if (ev.key !== KEY && ev.key !== null) return;
    show(saved() || system());
  });

  label();
  window.nanopiTheme = { get: current, set: apply, reset: reset };
})();
