// Whisker product site: demos and small enhancements. Everything here is optional; the pages read fine without it.
(() => {
  "use strict";
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const NS = "http://www.w3.org/2000/svg";

  // Copy buttons.
  for (const button of $$("[data-copy]")) {
    button.hidden = false;
    button.addEventListener("click", async () => {
      const source = document.getElementById(button.dataset.copy);
      const text = source ? source.textContent.trim() : "";
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        const range = document.createRange();
        range.selectNodeContents(source);
        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        button.textContent = "Selected";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 2000);
    });
  }

  // Example profiles; mappings merge over Default by trigger and modifiers,
  // the same way Whisker resolves an app profile.
  const schematic = $("#schematic");
  if (schematic) {
    const parts = {
      primary: { name: "Primary button", base: ["Primary click", "Only remapped with a modifier key, unless you allow it in General › Safety."] },
      secondary: { name: "Secondary button", base: ["Secondary click", "Left as it is."] },
      middle: { name: "Middle button", base: ["Middle click", "Left as it is."] },
      wheel: { name: "Wheel", base: ["Scrolls", "The distance macOS normally uses."] },
      b4: { name: "Button 4", base: ["Button 4 click", ""] },
      b5: { name: "Button 5", base: ["Button 5 click", ""] },
    };
    const profiles = {
      default: { name: "Default", maps: {
        b4: { "": ["Back", "Sends ⌘["] },
        b5: { "": ["Forward", "Sends ⌘]"] },
        middle: { "⌃": ["Mission Control", ""] },
        wheel: { "⌥": ["Volume Up / Down", "Repeat for every notch"] },
      } },
      safari: { name: "Safari", maps: {
        middle: { "": ["Click", "Primary button with ⌘, so links open in a new tab"] },
        wheel: { "": ["Scrolls 5 lines per notch", "Set how far each notch scrolls"] },
      } },
      finder: { name: "Finder", maps: {
        middle: { "": ["Keyboard Shortcut", "⌘↑ opens the enclosing folder"] },
      } },
      xcode: { name: "Xcode", maps: {
        b4: { "": ["Keyboard Shortcut", "⌃⌘← goes back in the editor"] },
        b5: { "": ["Keyboard Shortcut", "⌃⌘→ goes forward"] },
        middle: { "": ["Keyboard Shortcut", "⇧⌘O, Open Quickly"] },
      } },
    };
    const callout = $("#callout");
    const announcer = $("#schematic-status");
    let profile = "default";
    let part = "b4";

    const resolve = (profileID, partID) => {
      const rows = new Map();
      const base = profiles.default.maps[partID] || {};
      for (const [mods, action] of Object.entries(base)) rows.set(mods, { action, inherited: profileID !== "default" });
      if (profileID !== "default") {
        for (const [mods, action] of Object.entries(profiles[profileID].maps[partID] || {})) rows.set(mods, { action, inherited: false });
      }
      if (!rows.has("")) rows.set("", { action: parts[partID].base, inherited: false, unmapped: true });
      return [...rows.entries()].sort(([a], [b]) => a.length - b.length);
    };

    const render = () => {
      const rows = resolve(profile, part);
      const list = document.createElement("ul");
      list.className = "maps";
      for (const [mods, row] of rows) {
        const li = document.createElement("li");
        const key = document.createElement("span");
        key.className = "key";
        key.textContent = mods ? `${mods} + ${parts[part].name.replace(" button", "")}` : "On its own";
        const act = document.createElement("span");
        act.className = "act";
        act.textContent = row.action[0];
        if (row.action[1]) {
          const small = document.createElement("small");
          small.textContent = row.action[1];
          act.append(small);
        }
        if (row.inherited) {
          const tag = document.createElement("span");
          tag.className = "inh";
          tag.textContent = "Inherited from Default";
          act.append(tag);
        }
        li.append(key, act);
        list.append(li);
      }
      const title = document.createElement("h3");
      title.textContent = parts[part].name;
      const tag = document.createElement("span");
      tag.className = "label";
      tag.textContent = profiles[profile].name;
      title.append(tag);
      callout.replaceChildren(title, list);

      for (const b of $$("[data-part]", schematic)) b.setAttribute("aria-pressed", String(b.dataset.part === part));
      for (const b of $$("[data-profile]", schematic)) b.setAttribute("aria-pressed", String(b.dataset.profile === profile));
      for (const el of $$("[data-hot]", schematic)) el.classList.toggle("is-active", el.dataset.hot === part);
      const own = rows.find(([mods]) => mods === "")[1];
      announcer.textContent = `${parts[part].name} in ${profiles[profile].name}: ${own.action[0]}${own.inherited ? ", inherited from Default" : ""}.`;
    };

    for (const b of $$("[data-part]", schematic)) b.addEventListener("click", () => { part = b.dataset.part; render(); });
    for (const b of $$("[data-profile]", schematic)) b.addEventListener("click", () => { profile = b.dataset.profile; render(); });
    for (const el of $$(".part[data-hot]", schematic)) {
      el.addEventListener("click", () => { part = el.dataset.hot; render(); });
      el.addEventListener("pointerenter", () => { part = el.dataset.hot; render(); });
    }
    for (const el of $$("[data-js-only]", schematic)) el.hidden = false;
    render();
  }

  // Plot helpers.
  const plotLine = (svg, cls, points) => {
    let path = $(`path.${cls}`, svg);
    if (!path) {
      path = document.createElementNS(NS, "path");
      path.setAttribute("class", cls);
      svg.append(path);
    }
    path.setAttribute("d", points.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(1)} ${y.toFixed(1)}`).join(" "));
  };
  const box = { x0: 44, x1: 330, y0: 186, y1: 14 };
  const sx = (v, max) => box.x0 + (v / max) * (box.x1 - box.x0);
  const sy = (v, max) => box.y0 - (Math.min(v, max) / max) * (box.y0 - box.y1);

  // Lines for one notch follow Whisker's own formula, L × (1 + k × max(0, rate − 4)).
  const wheel = $("#wheel-demo");
  if (wheel) {
    const linesInput = $("#lines", wheel);
    const accelInput = $("#spin", wheel);
    const reverse = $("#reverse", wheel);
    const list = $("#page-lines", wheel);
    const readout = $("#wheel-readout", wheel);
    const plot = $("#wheel-plot", wheel);
    const rowHeight = () => list.firstElementChild.getBoundingClientRect().height || 25.6;
    const total = list.children.length;
    let offset = 0;

    const effective = (base, k, rate) => Math.max(base, Math.round(base * (1 + k * Math.max(0, rate - 4))));
    const draw = () => {
      const base = Number(linesInput.value);
      const k = Number(accelInput.value);
      $("#lines-out", wheel).value = `${base}`;
      $("#spin-out", wheel).value = k.toFixed(2);
      const pts = [];
      for (let r = 0; r <= 20; r += 0.1) pts.push([sx(r, 20), sy(effective(base, k, r), 60)]);
      plotLine(plot, "curve", pts);
    };
    const turn = (notch) => {
      const lines = Number(linesInput.value) * (reverse.checked ? -notch : notch);
      const visible = Math.floor(list.parentElement.clientHeight / rowHeight());
      offset = Math.max(0, Math.min(total - visible, offset + lines));
      list.style.transform = `translateY(${-offset * rowHeight()}px)`;
      readout.textContent = `Wheel ${notch > 0 ? "down" : "up"} · page moves ${lines > 0 ? "down" : "up"} ${Math.abs(lines)}`;
    };
    $("#wheel-up", wheel).addEventListener("click", () => turn(-1));
    $("#wheel-down", wheel).addEventListener("click", () => turn(1));
    $(".page-window", wheel).addEventListener("wheel", (event) => {
      if (Math.abs(event.deltaY) < 1) return;
      event.preventDefault();
      turn(Math.sign(event.deltaY));
    }, { passive: false });
    linesInput.addEventListener("input", draw);
    accelInput.addEventListener("input", draw);
    for (const el of $$("[data-js-only]", wheel)) el.hidden = false;
    draw();
  }

  // The pointer's response is illustrative; the confirm-or-revert rule is Whisker's own:
  // more than double the last confirmed speed must be kept within five seconds.
  const pointer = $("#pointer-demo");
  if (pointer) {
    const speed = $("#speed", pointer);
    const accel = $("#accel", pointer);
    const linear = $("#linear", pointer);
    const plot = $("#pointer-plot", pointer);
    const confirmBox = $("#confirm", pointer);
    const meter = $(".meter span", confirmBox);
    const status = $("#pointer-status", pointer);
    const runway = $("#pointer-runway", pointer);
    const moveStatus = $("#move-status", pointer);
    let confirmed = Number(speed.value);
    let timer = 0;

    const travel = (s, a, v) => s * v * (1 + a * 1.6 * v);
    const draw = () => {
      const s = Number(speed.value);
      const a = linear.checked ? 0 : Number(accel.value);
      accel.disabled = linear.checked;
      $("#speed-out", pointer).value = `×${s.toFixed(1)}`;
      $("#accel-out", pointer).value = linear.checked ? "off" : a.toFixed(2);
      const pts = [];
      const ref = [];
      for (let v = 0; v <= 1.0001; v += 0.02) {
        pts.push([sx(v, 1), sy(travel(s, a, v), 8)]);
        ref.push([sx(v, 1), sy(travel(1, 0.6875, v), 8)]);
      }
      plotLine(plot, "ref", ref);
      plotLine(plot, "curve", pts);
      const distance = Math.min(1, travel(s, a, 0.7) / 5);
      runway.classList.remove("playing");
      runway.style.setProperty("--travel", `${(distance * 100).toFixed(2)}%`);
      runway.style.setProperty("--travel-scale", String(distance));
    };
    const settle = (message) => {
      clearTimeout(timer);
      confirmBox.hidden = true;
      meter.classList.remove("run");
      status.textContent = message;
    };
    speed.addEventListener("input", draw);
    accel.addEventListener("input", draw);
    linear.addEventListener("change", draw);
    speed.addEventListener("change", () => {
      const s = Number(speed.value);
      if (s <= confirmed * 2) {
        confirmed = s;
        settle("");
        return;
      }
      clearTimeout(timer);
      confirmBox.hidden = false;
      meter.classList.remove("run");
      void meter.offsetWidth;
      meter.classList.add("run");
      status.textContent = "";
      timer = setTimeout(() => {
        speed.value = String(confirmed);
        draw();
        settle(`Not kept, so the speed went back to ×${confirmed.toFixed(1)}.`);
      }, 5000);
    });
    $("#keep", pointer).addEventListener("click", () => { confirmed = Number(speed.value); settle(`Kept ×${confirmed.toFixed(1)}.`); });
    $("#revert", pointer).addEventListener("click", () => {
      speed.value = String(confirmed);
      draw();
      settle(`Changed back to ×${confirmed.toFixed(1)}.`);
    });
    $("#pointer-play", pointer).addEventListener("click", () => {
      runway.classList.remove("playing");
      if (!reduceMotion.matches) {
        void runway.offsetWidth;
        runway.classList.add("playing");
      }
      moveStatus.textContent = `Illustrative move at ×${Number(speed.value).toFixed(1)} speed, ${linear.checked ? "without acceleration" : `with ${Number(accel.value).toFixed(2)} acceleration`}.`;
    });
    for (const el of $$("[data-js-only]", pointer)) el.hidden = false;
    draw();
  }

  // Guide: mark the section being read in the contents.
  const toc = $(".toc");
  if (toc && "IntersectionObserver" in window) {
    const links = new Map($$("a[href^='#']", toc).map((a) => [a.getAttribute("href").slice(1), a]));
    const spy = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const link = links.get(entry.target.id);
        if (!link) continue;
        for (const a of links.values()) a.removeAttribute("aria-current");
        link.setAttribute("aria-current", "true");
      }
    }, { rootMargin: "-20% 0px -70% 0px" });
    for (const id of links.keys()) {
      const target = document.getElementById(id);
      if (target && target.tagName === "H2") spy.observe(target);
    }
  }
})();
