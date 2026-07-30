(function () {
  var HIDE_MS = 5000;
  var timer;

  function host() {
    return document.getElementById("toast-host");
  }

  function clear() {
    clearTimeout(timer);
    timer = null;
    var el = host();
    if (el) el.innerHTML = "";
  }

  function arm() {
    var el = host();
    if (!el || !el.querySelector(".toast")) return;
    clearTimeout(timer);
    timer = setTimeout(clear, HIDE_MS);
  }

  function show(text, isErr) {
    var el = host();
    if (!el) return;
    el.innerHTML =
      '<div class="toast ' +
      (isErr ? "toast-err" : "toast-ok") +
      '" role="' +
      (isErr ? "alert" : "status") +
      '">' +
      '<button type="button" class="toast-close" aria-label="Закрыть">×</button>' +
      '<div class="toast-title">' +
      (isErr ? "Ошибка" : "Уведомление") +
      "</div>" +
      '<div class="toast-body"></div></div>';
    el.querySelector(".toast-body").textContent = text;
    arm();
  }

  document.body.addEventListener("click", function (ev) {
    if (!ev.target.closest || !ev.target.closest(".toast-close")) return;
    clear();
  });

  document.body.addEventListener("htmx:afterSwap", function (ev) {
    if (ev.target && ev.target.id === "toast-host") arm();
  });

  document.body.addEventListener("htmx:oobAfterSwap", function (ev) {
    if (ev.target && ev.target.id === "toast-host") arm();
  });

  window.nanopiToast = { show: show, clear: clear, arm: arm };
})();
