(function () {
  function toggleWanFields(sel) {
    var box = document.getElementById("wan-pppoe-fields");
    if (!box) return;
    box.hidden = sel.value !== "pppoe";
  }

  function togglePass() {
    var input = document.getElementById("wan-pass");
    var btn = document.querySelector(".pass-toggle");
    if (!input) return;
    var show = input.type === "password";
    input.type = show ? "text" : "password";
    if (btn) btn.textContent = show ? "скрыть" : "показать";
  }

  function wanBusy() {
    var root = document.getElementById("wan");
    if (!root) return false;
    if (root.querySelector("input:focus, select:focus, textarea:focus")) return true;
    var pass = document.getElementById("wan-pass");
    if (pass && pass.type === "text") return true;
    return false;
  }

  window.nanopiToggleWanFields = toggleWanFields;
  window.nanopiTogglePass = togglePass;

  document.body.addEventListener("htmx:beforeRequest", function (ev) {
    var elt = ev.detail && ev.detail.elt;
    if (elt && elt.id === "wan" && ev.detail.requestConfig && ev.detail.requestConfig.verb === "get") {
      if (wanBusy()) {
        ev.preventDefault();
      }
    }
  });

  document.body.addEventListener("htmx:afterSwap", function (ev) {
    if (ev.target && ev.target.id === "wan") {
      var sel = document.getElementById("wan-mode");
      if (sel) toggleWanFields(sel);
    }
  });
})();
