(function () {
  var el = document.getElementById("log-view");
  if (!el) return;

  var clearBtn = document.getElementById("log-clear");
  if (clearBtn) {
    clearBtn.addEventListener("click", function () {
      el.innerHTML = "";
    });
  }

  if (!window.EventSource) return;

  function escapeHtml(s) {
    return s
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function lineEl(text) {
    var d = document.createElement("div");
    d.className = "log-line";
    d.innerHTML = escapeHtml(text).replace(/\bERROR\b/g, '<span class="log-level-error">ERROR</span>');
    return d;
  }

  var es = new EventSource("/logs/stream");
  es.onmessage = function (ev) {
    var line = ev.data;
    if (!line) return;
    el.insertBefore(lineEl(line), el.firstChild);
    el.scrollTop = 0;
  };
})();
