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
  const overlayDismiss = document.getElementById("update-overlay-dismiss");
  if (!dialog || !checkBtn) return;

  let pendingTag = "";
  let waiting = false;

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

  function hideOverlay() {
    waiting = false;
    if (overlay) overlay.hidden = true;
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

  async function fetchVersion() {
    const r = await fetch("/api/version", { cache: "no-store" });
    if (!r.ok) return null;
    return r.json();
  }

  async function waitUntilApplyDone(expected, tries) {
    let lastStatus = null;
    let webuiOkStreak = 0;
    for (let i = 0; i < tries; i++) {
      if (!waiting) {
        return { ok: false, status: lastStatus, message: "Ожидание отменено" };
      }
      await sleep(1500);

      // Сначала версия панели: status=ok может не записаться, если воркер
      // убили на restart вместе с cgroup webui.
      try {
        const j = await fetchVersion();
        if (j && normVer(j.version) === normVer(expected)) {
          webuiOkStreak++;
          if (overlayStep) {
            overlayStep.textContent =
              "WebUI " + j.version + " готов" +
              (j.edge_version ? ", Edge " + j.edge_version : "");
          }
          if (webuiOkStreak >= 2) {
            return {
              ok: true,
              status: lastStatus,
              version: { version: j.version, edge: j.edge_version },
            };
          }
        } else {
          webuiOkStreak = 0;
        }
      } catch (_) {
        webuiOkStreak = 0;
        if (overlayStep) {
          overlayStep.textContent = "Панель перезапускается…";
        }
      }

      try {
        const r = await fetch("/api/updates/status", { cache: "no-store" });
        if (r.ok) {
          const st = await r.json();
          lastStatus = st;
          if (st.state === "error") {
            return { ok: false, status: st };
          }
          // Не затирать «WebUI готов», если версия уже совпала.
          if (webuiOkStreak === 0 && overlayStep) {
            overlayStep.textContent =
              stepLabel(st.step) + (st.version ? " → " + st.version : "");
          }
          if (st.state === "ok" && normVer(st.version) === normVer(expected) && webuiOkStreak >= 1) {
            return { ok: true, status: st };
          }
        }
      } catch (_) {
        /* сеть моргнула */
      }
    }
    return { ok: false, status: lastStatus, message: "Таймаут ожидания apply" };
  }

  async function applyUpdate() {
    if (!pendingTag) return;
    if (
      !confirm(
        "Обновить до " +
          pendingTag +
          "?\n\nСначала edge, затем WebUI.\nСтраница обновится, когда панель ответит новой версией."
      )
    ) {
      return;
    }
    dialog.close();
    waiting = true;
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
        hideOverlay();
        alert(j.error || "Не удалось запустить обновление");
        return;
      }
    } catch (_) {
      /* сеть моргнула — статус всё равно поллим */
    }

    const result = await waitUntilApplyDone(expected, 160);
    hideOverlay();
    if (result.ok) {
      location.reload();
      return;
    }
    if (result.message === "Ожидание отменено") {
      return;
    }
    const st = result.status || {};
    alert(
      (result.message || "Обновление не завершилось") +
        (st.error ? "\n" + st.error : "") +
        (st.step ? "\nШаг: " + st.step : "") +
        "\nЛог: /opt/nanopi-edge/update.log\nМожно просто обновить страницу (F5)."
    );
  }

  if (overlayDismiss) {
    overlayDismiss.addEventListener("click", function () {
      hideOverlay();
      location.reload();
    });
  }

  checkBtn.addEventListener("click", checkUpdates);
  applyBtn.addEventListener("click", applyUpdate);
})();
