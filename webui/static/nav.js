// Подсветка текущего пункта меню: шаблон nav получает разные данные
// на разных страницах, поэтому активный пункт определяем по адресу.
(function () {
  var path = location.pathname.replace(/\/+$/, "") || "/";
  document.querySelectorAll("header.top nav a").forEach(function (a) {
    var href = a.getAttribute("href");
    var on = href === "/" ? path === "/" : path === href || path.indexOf(href + "/") === 0;
    if (on) {
      a.classList.add("active");
      a.setAttribute("aria-current", "page");
    }
  });
})();
