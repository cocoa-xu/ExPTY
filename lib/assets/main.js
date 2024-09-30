import * as Vue from "https://cdn.jsdelivr.net/npm/vue@3.2.26/dist/vue.esm-browser.prod.js";
import { Base } from "./base.js";

export async function init(ctx, info) {
  await Promise.all([
    ctx.importCSS("main.css"),
    ctx.importCSS("https://fonts.googleapis.com/css2?family=Inter:wght@400;500&display=swap"),
    ctx.importCSS("https://cdn.jsdelivr.net/npm/remixicon@4.3.0/fonts/remixicon.min.css"),
    ctx.importCSS("xterm.css"),
    ctx.importJS("xterm.js"),
    ctx.importJS("xterm-addon-fit.js")
  ])

  const DEFAULT_ROWS = 24;
  const DEFAULT_COLS = 80;
  var term = new Terminal({
    rows: DEFAULT_ROWS,
    cols: DEFAULT_COLS
  });
  var resizeObserver = null;

  const fit_addon = new FitAddon.FitAddon()
  term.loadAddon(fit_addon)

  function fullscreenchanged() {
    try {
      if (document.fullscreenElement === null) {
        term.resize(DEFAULT_COLS, DEFAULT_ROWS)
      }
      fit_addon && fit_addon.fit()
    }
    catch (err) {
      console.log(err)
    }
  }

  var appConfig = {
    components: {
      BaseInput: Base.BaseInput,
      BaseSelect: Base.BaseSelect,
    },

    props: {
      fields: {
        type: Object,
        default: {},
      }
    },

    data() {
      return {
        opened: false,
        fields: this.fields,
      }
    },

    template: `
    <div class="app">
      <div class="header">
        <BaseInput
          name="executable"
          label="Executable Path"
          type="text"
          placeholder="/bin/bash"
          v-model="fields.executable"
          inputClass="input input--xs"
          :grow
          :required
        />
        <button id="start-stop-button" @click="start_stop_executable" class="icon-button">
          <i class="ri ri-play-line" data-start-stop-button></i>
        </button>
        <button id="fullscreen-button" @click="enter_fullscreen" class="icon-button">
          <i class="ri ri-focus-mode" data-fullscreen-button></i>
        </button>
      </div>
      <div class="terminal" id="terminal"></div>
    </div>
    `,

    methods: {
      start_stop_executable() {
        const button = ctx.root.querySelector("[data-start-stop-button]");
        const classList = button.classList;
        const terminalEl = ctx.root.querySelector('#terminal');
        if (classList.contains("ri-stop-line")) {
          ctx.pushEvent("stop_executable");
          button.classList.remove("ri-stop-line");
          button.classList.add("ri-play-line");

          if (resizeObserver !== null) {
            resizeObserver.unobserve(terminalEl);
            resizeObserver.disconnect();
          }
        } else {
          ctx.pushEvent("start_executable", {executable: this.fields.executable});
          button.classList.remove("ri-play-line");
          button.classList.add("ri-stop-line");

          if (!this.opened) {
            term.open(terminalEl)
            terminalEl.onfullscreenchange = fullscreenchanged;
            term.onResize((evt) => {
              console.log({cols: evt.cols, rows: evt.rows})
              ctx.pushEvent("resize", {cols: evt.cols, rows: evt.rows})
            })
            this.opened = true;
          } else {
            term.clear()
          }

          fit_addon.fit()
          resizeObserver = new ResizeObserver((entries) => {
            try {
              fit_addon && fit_addon.fit()
            } catch (err) {
              console.log(err)
            }
          })
          resizeObserver.observe(terminalEl)
        }
      },
      enter_fullscreen() {
        const button = ctx.root.querySelector("[data-start-stop-button]");
        const terminal = ctx.root.querySelector("#terminal");
        if (button.classList.contains("ri-stop-line") && terminal !== undefined) {
          terminal.requestFullscreen().catch((err) => {
            console.log(err)
          })
          try {
            fit_addon && fit_addon.fit()
          } catch (err) {
            console.log(err)
          }
        }
      }
    }
  };
  const app = Vue.createApp(appConfig).mount(ctx.root);

  ctx.handleEvent("update", ({ fields }) => {
    setValues(fields);
  });

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

  function setValues(fields) {
    for (const field in fields) {
      app.fields[field] = fields[field];
    }
  }
}
