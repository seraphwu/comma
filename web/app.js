function render(md) {
  const out = document.getElementById('out');
  const y = window.scrollY;
  out.innerHTML = marked.parse(md);
  for (const code of out.querySelectorAll('pre > code.language-mermaid')) {
    const box = document.createElement('div');
    box.className = 'pele';
    code.parentElement.replaceWith(box);
    try {
      pele.mount(box, code.textContent, {
        onError: (e) => { box.className = 'pele-error'; box.textContent = '流程圖錯誤：' + (e?.message ?? e); },
      });
    } catch (e) {
      box.className = 'pele-error';
      box.textContent = '流程圖錯誤：' + (e?.message ?? e);
    }
  }
  window.scrollTo(0, y);
}
