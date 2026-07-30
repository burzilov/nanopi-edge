(function () {
  window.nanopiApplyVlessPreset = function (sel) {
    if (!sel || !sel.value) return;
    var parts = sel.value.split("|");
    if (parts.length < 3) return;
    var form = document.getElementById("mv-settings");
    if (!form) return;
    var hs = form.querySelector('[name="handshake_server"]');
    var hp = form.querySelector('[name="handshake_port"]');
    var sn = form.querySelector('[name="server_name"]');
    if (hs) hs.value = parts[0];
    if (hp) hp.value = parts[1];
    if (sn) sn.value = parts[2];
  };

  window.nanopiCopyVlessURI = function () {
    var ta = document.getElementById("mv-uri");
    if (!ta) return;
    var text = ta.value || "";
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        if (window.nanopiToast) window.nanopiToast("URI скопирован");
      }).catch(function () {
        ta.select();
        document.execCommand("copy");
      });
      return;
    }
    ta.select();
    document.execCommand("copy");
  };
})();
