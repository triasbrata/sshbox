'use strict';

// Draws one Mermaid diagram for the app's Markdown preview. The app calls
// render() with the source as JSON data, and the page tells it one thing
// back: its height, as a number, on the Height channel.

// A taller diagram is drawn smaller to fit. The app shows the page at its
// full height, as a texture that size, and GPUs cap a texture at 8192 or
// 16384 pixels, which 4000 dp stays under up to a density of 4.
const MAX_HEIGHT = 4000;

async function render(source, options) {
  document.body.style.background = options.bg;
  document.body.style.color = options.fg;
  const root = document.getElementById('d');
  mermaid.initialize({
    startOnLoad: false,
    // No HTML in labels, no click handlers, no links.
    securityLevel: 'strict',
    htmlLabels: false,
    flowchart: { htmlLabels: false },
    suppressErrorRendering: true,
    theme: options.dark ? 'dark' : 'default',
  });
  try {
    const { svg } = await mermaid.render('m', source);
    root.innerHTML = svg;
    // Strict still links a flowchart node given `click A "https://…"`.
    for (const a of root.querySelectorAll('a')) a.replaceWith(...a.childNodes);
    // Mermaid fits a diagram to the page by default, which shrinks a wide
    // one past reading; drawn at its own size, it scrolls instead.
    const el = root.querySelector('svg');
    const box = el.viewBox.baseVal;
    const rect = el.getBoundingClientRect();
    let width = box && box.width ? box.width : rect.width;
    let height = box && box.height ? box.height : rect.height;
    if (height > MAX_HEIGHT) {
      width = width * MAX_HEIGHT / height;
      height = MAX_HEIGHT;
    }
    el.setAttribute('width', width);
    el.setAttribute('height', height);
    el.style.maxWidth = 'none';
  } catch (e) {
    // Never a blank space: what Mermaid said, then the source as written.
    const message = document.createElement('pre');
    message.style.color = options.error;
    message.textContent = String((e && e.message) || e);
    const code = document.createElement('pre');
    code.textContent = source;
    root.replaceChildren(message, code);
  }
  Height.postMessage(String(Math.ceil(root.getBoundingClientRect().height)));
}
