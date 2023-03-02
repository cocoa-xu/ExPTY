export async function init(ctx, info) {
  await Promise.all([
    ctx.importCSS("xterm.css"),
    ctx.importJS("xterm.js"),
    ctx.importJS("xterm-addon-fit.js")
  ])

  ctx.root.innerHTML = `<div id="terminal"></div>`

  var term = new Terminal({
    rows: 24,
    cols: 80
  })

  const fit_addon = new FitAddon.FitAddon()
  term.loadAddon(fit_addon)
  term.open(document.getElementById('terminal'))
  term.onResize((evt) => {
    console.log({cols: evt.cols, rows: evt.rows})
    ctx.pushEvent("resize", {cols: evt.cols, rows: evt.rows})
  })
  fit_addon.fit()

  const term_resize_ob = new ResizeObserver((entries) => {
    try {
      fit_addon && fit_addon.fit()
    } catch (err) {
      console.log(err)
    }
  })
  term_resize_ob.observe(document.getElementById('terminal'))

  term.onData((data) => {
    ctx.pushEvent("on_key", {data: btoa(data)})
  })

  ctx.handleEvent("data", ({ data }) => {
    term.write(Uint8Array.from(atob(data), c => c.charCodeAt(0)))
  })

  ctx.handleSync(() => {
    // Synchronously invokes change listeners
    document.activeElement &&
      document.activeElement.dispatchEvent(
        new Event("change", { bubbles: true })
      )
  })
}
