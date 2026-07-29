(function () {
  const dialog = document.getElementById("updates-dialog");
  const statusEl = document.getElementById("updates-status");
  const detailEl = document.getElementById("updates-detail");
  const notesEl = document.getElementById("updates-notes");
  const applyBtn = document.getElementById("btn-apply-update");
  const checkBtn = document.getElementById("btn-check-updates");
  const overlay = document.getElementById("update-overlay");
  const overlayTitle = document.getElementById("update-overlay-title");
  if (!dialog || !checkBtn) return;

  let pendingTag = "";

  function setStatus(text, isErr) {
    statusEl.textContent = text;
    statusEl.classList.toggle("err", !!isErr);
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  async function checkUpdates() {
    pendingTag = "";
    applyBtn.hidden = true;
    notesEl.hidden = true;
    notesEl.textContent = "";
    detailEl.hidden = true;
    detailEl.textContent = "";
    setStatus("Проверяю GitHub Releases…", false);
    dialog.showModal();
    try {
      const r = await fetch("/api/updates/check", { headers: { Accept: "application/json" } });
      const j = await r.json();
      if (!r.ok) {
        setStatus(j.error || "Ошибка проверки", true);
        return;
      }
      const webuiCur = (j.webui && j.webui.current) || "?";
      const edgeCur = (j.edge && j.edge.current) || "?";
      detailEl.textContent =
        "Сейчас: WebUI " + webuiCur + ", Edge " + edgeCur;
      detailEl.hidden = false;

      if (j.update_available) {
        pendingTag = j.latest;
        setStatus("Доступна " + j.latest + ". Можно обновить edge и панель.", false);
        if (j.body) {
          notesEl.textContent = j.body;
          notesEl.hidden = false;
        }
        applyBtn.hidden = false;
      } else {
        setStatus("Актуально: " + (j.latest || webuiCur), false);
      }
    } catch (e) {
      setStatus(String(e), true);
    }
  }

  async function waitForVersion(expected, tries) {
    for (let i = 0; i < tries; i++) {
      await sleep(2500);
      try {
        const r = await fetch("/api/version", { cache: "no-store" });
        if (!r.ok) continue;
        const j = await r.json();
        if (!j.version) continue;
        if (
          !expected ||
          j.version === expected ||
          j.version.replace(/^v/, "") === String(expected).replace(/^v/, "")
        ) {
          return j.version;
        }
        if (i > 3) return j.version;
      } catch (_) {
        /* панель ещё лежит после webui */
      }
    }
    return null;
  }

  async function applyUpdate() {
    if (!pendingTag) return;
    if (
      !confirm(
        "Обновить до " +
          pendingTag +
          "?\n\nСначала edge (scripts/sing-box), затем WebUI.\nconfig.json не пересобирается."
      )
    ) {
      return;
    }
    dialog.close();
    overlay.hidden = false;
    if (overlayTitle) {
      overlayTitle.textContent = "Обновляю до " + pendingTag + "…";
    }
    const expected = pendingTag;
    try {
      await fetch("/api/updates/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ version: pendingTag }),
      });
    } catch (_) {
      /* обрыв при рестарте webui — ожидаемо */
    }
    const ver = await waitForVersion(expected, 60);
    overlay.hidden = true;
    if (ver) {
      location.reload();
    } else {
      alert(
        "Панель долго не отвечает. Проверь: systemctl status nanopi-webui sing-box"
      );
    }
  }

  checkBtn.addEventListener("click", checkUpdates);
  applyBtn.addEventListener("click", applyUpdate);
})();
