(function () {
  const dialog = document.getElementById("updates-dialog");
  const statusEl = document.getElementById("updates-status");
  const detailEl = document.getElementById("updates-detail");
  const notesEl = document.getElementById("updates-notes");
  const applyBtn = document.getElementById("btn-apply-update");
  const checkBtn = document.getElementById("btn-check-updates");
  const overlay = document.getElementById("update-overlay");
  const overlayTitle = document.getElementById("update-overlay-title");
  const overlayStep = document.getElementById("update-overlay-step");
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

  function normVer(v) {
    return String(v || "").replace(/^v/, "");
  }

  function stepLabel(step) {
    switch (step) {
      case "starting":
        return "Запуск…";
      case "edge":
        return "Обновляю edge (sing-box / scripts)…";
      case "webui":
        return "Обновляю WebUI…";
      case "done":
        return "Готово";
      default:
        return step ? String(step) : "Обновление…";
    }
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
      if (j.edge && j.edge.error) {
        detailEl.textContent += "\n" + j.edge.error;
      }

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

  async function waitUntilApplyDone(expected, tries) {
    let lastStatus = null;
    for (let i = 0; i < tries; i++) {
      await sleep(2000);
      try {
        const r = await fetch("/api/updates/status", { cache: "no-store" });
        if (!r.ok) continue;
        const st = await r.json();
        lastStatus = st;
        if (overlayStep) {
          overlayStep.textContent = stepLabel(st.step) +
            (st.version ? " → " + st.version : "");
        }
        if (st.state === "error") {
          return { ok: false, status: st };
        }
        if (st.state === "ok" && normVer(st.version) === normVer(expected)) {
          // дождаться, пока новая панель отдаст обе версии
          const ver = await waitForBothVersions(expected, 30);
          if (ver.matched) {
            return { ok: true, status: st, version: ver };
          }
          return {
            ok: false,
            status: st,
            version: ver,
            message:
              "Apply завершён, но /api/version ещё не совпал (webui/edge).",
          };
        }
      } catch (_) {
        if (overlayStep) {
          overlayStep.textContent = "Панель перезапускается…";
        }
      }
    }
    return { ok: false, status: lastStatus, message: "Таймаут ожидания apply" };
  }

  async function waitForBothVersions(expected, tries) {
    let last = null;
    for (let i = 0; i < tries; i++) {
      await sleep(2000);
      try {
        const r = await fetch("/api/version", { cache: "no-store" });
        if (!r.ok) continue;
        const j = await r.json();
        last = j;
        const webuiOk = normVer(j.version) === normVer(expected);
        const edgeOk =
          !!j.edge_version &&
          normVer(j.edge_version) === normVer(expected);
        if (webuiOk && edgeOk) {
          return { matched: true, version: j.version, edge: j.edge_version };
        }
      } catch (_) {
        /* ещё лежит */
      }
    }
    return {
      matched: false,
      version: last && last.version,
      edge: last && last.edge_version,
    };
  }

  async function applyUpdate() {
    if (!pendingTag) return;
    if (
      !confirm(
        "Обновить до " +
          pendingTag +
          "?\n\nСначала edge, затем WebUI.\nСтраница обновится только когда оба компонента будут на этой версии."
      )
    ) {
      return;
    }
    dialog.close();
    overlay.hidden = false;
    if (overlayTitle) {
      overlayTitle.textContent = "Обновляю до " + pendingTag + "…";
    }
    if (overlayStep) {
      overlayStep.textContent = "Запуск…";
    }
    const expected = pendingTag;
    try {
      const r = await fetch("/api/updates/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json" },
        body: JSON.stringify({ version: pendingTag }),
      });
      const j = await r.json().catch(function () {
        return {};
      });
      if (!r.ok && r.status !== 202) {
        overlay.hidden = true;
        alert(j.error || "Не удалось запустить обновление");
        return;
      }
    } catch (_) {
      /* сеть моргнула — статус всё равно поллим */
    }

    const result = await waitUntilApplyDone(expected, 120);
    overlay.hidden = true;
    if (result.ok) {
      location.reload();
      return;
    }
    const st = result.status || {};
    alert(
      (result.message || "Обновление не завершилось") +
        (st.error ? "\n" + st.error : "") +
        (st.step ? "\nШаг: " + st.step : "") +
        "\nЛог: /opt/nanopi-edge/update.log"
    );
  }

  checkBtn.addEventListener("click", checkUpdates);
  applyBtn.addEventListener("click", applyUpdate);
})();
