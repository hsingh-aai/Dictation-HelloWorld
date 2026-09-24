// Two screens behind one menu bar. Dictation is the default; #intake opens the form.
const screens = { dictation: 'screen-dictation', intake: 'screen-intake' };

function show() {
  const name = location.hash.slice(1) in screens ? location.hash.slice(1) : 'dictation';
  for (const [key, id] of Object.entries(screens)) document.getElementById(id).hidden = key !== name;
  document.querySelectorAll('.menubar a').forEach((a) => {
    if (a.dataset.screen === name) a.setAttribute('aria-current', 'page');
    else a.removeAttribute('aria-current');
  });
  document.body.dataset.screen = name;
  document.title = name === 'intake' ? 'Intake Form · Dictation Demo' : 'Dictation Demo';
  // Leaving a screen mid-recording would leave the mic open where you can't see it.
  window.dispatchEvent(new CustomEvent('screenchange', { detail: name }));
}

window.addEventListener('hashchange', show);
show();
