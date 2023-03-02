export async function init(ctx, info) {
  await Promise.all([
    ctx.importCSS("xterm.css"),
    ctx.importJS("xterm.js")
  ])

  ctx.root.innerHTML = `<div id="terminal"></div>`

  var term = new Terminal({
    rows: 24,
    cols: 80
  })

  term.open(document.getElementById('terminal'))

  term.onData((data) => {
    ctx.pushEvent("on_key", {data: btoa(data)})
  })

  ctx.handleEvent("data", ({ data }) => {
    term.write(data)
  })

  ctx.handleSync(() => {
    // Synchronously invokes change listeners
    document.activeElement &&
      document.activeElement.dispatchEvent(
        new Event("change", { bubbles: true })
      )
  })
}
