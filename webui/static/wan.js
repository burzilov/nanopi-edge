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
    if (!elt || !ev.detail.requestConfig || ev.detail.requestConfig.verb !== "get") return;
    if ((elt.id === "wan" || elt.id === "wan-info") && wanBusy()) {
      ev.preventDefault();
    }
  });

  document.body.addEventListener("submit", async function (ev) {
    var form = ev.target;
    if (!form || form.id !== "wan-mac-form") return;
    ev.preventDefault();
    var result = document.getElementById("wan-mac-result");
    var button = form.querySelector("button[type=submit]");
    var macInput = form.elements && form.elements.mac;
    if (!macInput) return;
    if (button) button.disabled = true;
    if (result) result.textContent = "Применяю…";
    try {
      var response = await fetch("/api/wan/mac", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({mac: macInput.value})
      });
      var data = await response.json();
      if (!response.ok || !data.ok) throw new Error(data.error || "Ошибка применения");
      if (data.status && Object.prototype.hasOwnProperty.call(data.status, "mac_configured")) {
        macInput.value = data.status.mac_configured || "";
      }
      if (result) result.textContent = data.warning || "MAC применён";
      if (window.htmx) htmx.trigger("#wan-info", "refresh");
    } catch (err) {
      if (result) result.textContent = err.message || "Ошибка применения";
    } finally {
      if (button) button.disabled = false;
    }
  });

  document.body.addEventListener("htmx:afterSwap", function (ev) {
    if (ev.target && ev.target.id === "wan") {
      var sel = document.getElementById("wan-mode");
      if (sel) toggleWanFields(sel);
    }
  });
})();
