/* Apply the persisted theme before the application stylesheet is evaluated. */
(function () {
  var themes = ['light', 'dark', 'ocean', 'forest', 'violet']
  var theme = 'light'
  try {
    var stored = localStorage.getItem('5gpn_theme')
    if (themes.indexOf(stored) !== -1) theme = stored
  } catch (_) {
    // Storage can be unavailable in hardened or private browser contexts.
  }
  document.documentElement.dataset.theme = theme
})()
