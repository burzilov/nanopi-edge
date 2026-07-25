(function () {
  const dialog = document.getElementById("updates-dialog");
  const statusEl = document.getElementById("updates-status");
  const notesEl = document.getElementById("updates-notes");
  const applyBtn = document.getElementById("btn-apply-update");
  const checkBtn = document.getElementById("btn-check-updates");
  const overlay = document.getElementById("update-overlay");
  if (!dialog || !checkBtn) return;

  let pendingTag = "";

  function setStatus(text, isErr) {
    statusEl.textContent = text;
    statusEl.classList.toggle("err", !!isErr);
  }

  async function checkUpdates() {
    pendingTag = "";
    applyBtn.hidden = true;
    notesEl.hidden = true;
    notesEl.textContent = "";
    setStatus("Проверяю GitHub Releases…", false);
    dialog.showModal();
    try {
      const r = await fetch("/api/updates/check", { headers: { Accept: "application/json" } });
      const j = await r.json();
      if (!r.ok) {
        setStatus(j.error || "Ошибка проверки", true);
        return;
      }
      if (j.update_available) {
        pendingTag = j.latest;
        setStatus(
          "Доступна " + j.latest + " (сейчас " + j.current + "). Можно установить.",
          false
        );
        if (j.body) {
          notesEl.textContent = j.body;
          notesEl.hidden = false;
        }
        applyBtn.hidden = false;
      } else {
        setStatus("Актуально: " + j.current + " (latest " + j.latest + ").", false);
      }
    } catch (e) {
      setStatus(String(e), true);
    }
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  async function waitForVersion(expected, tries) {
    for (let i = 0; i < tries; i++) {
      await sleep(2000);
      try {
        const r = await fetch("/api/version", { cache: "no-store" });
        if (!r.ok) continue;
        const j = await r.json();
        if (!j.version) continue;
        // панель снова отвечает; если версия совпала с ожидаемой — успех
        if (!expected || j.version === expected || j.version.replace(/^v/, "") === String(expected).replace(/^v/, "")) {
          return j.version;
        }
        // другая версия тоже значит, что рестарт прошёл
        if (i > 2) return j.version;
      } catch (_) {
        /* ещё лежит */
      }
    }
    return null;
  }

  async function applyUpdate() {
    if (!pendingTag) return;
    if (!confirm("Установить WebUI " + pendingTag + " и перезапустить панель?")) return;
    dialog.close();
    overlay.hidden = false;
    const expected = pendingTag;
    try {
      await fetch("/api/updates/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ version: pendingTag }),
      });
    } catch (_) {
      /* соединение оборвётся при restart — ожидаемо */
    }
    const ver = await waitForVersion(expected, 45);
    overlay.hidden = true;
    if (ver) {
      location.reload();
    } else {
      alert("Панель долго не отвечает. Проверь: systemctl status nanopi-webui");
    }
  }

  checkBtn.addEventListener("click", checkUpdates);
  applyBtn.addEventListener("click", applyUpdate);
})();
