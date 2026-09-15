(function () {
    const appEl = document.getElementById('app');
    const listEl = document.getElementById('recipe-list');
    const closeBtn = document.getElementById('closeBtn');
    const panelEl = document.getElementById('panel');
    const headerEl = document.getElementById('panel-header');

    function resourceName() {
        return (window.GetParentResourceName && GetParentResourceName()) || 'rsg-herbalist';
    }

    function post(endpoint, data) {
        return fetch(`https://${resourceName()}/${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        }).catch(() => {});
    }

    // All of the strings interpolated below (labels, descriptions, image
    // filenames) come from the server/config, not from player input, but
    // they still get escaped before landing in innerHTML - a modder adding
    // a tonic label/description containing markup (or a compromised/odd
    // item label from RSGCore.Shared.Items) shouldn't be able to inject
    // markup into this NUI page.
    function escapeHtml(value) {
        return String(value ?? '').replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
        }[c]));
    }

    function formatDuration(ms) {
        const totalSeconds = Math.round(ms / 1000);
        if (totalSeconds < 60) return `${totalSeconds}s`;
        const minutes = Math.floor(totalSeconds / 60);
        const seconds = totalSeconds % 60;
        return seconds > 0 ? `${minutes}m ${seconds}s` : `${minutes}m`;
    }

    function ingredientPill(ingredient) {
        const ok = ingredient.have >= ingredient.required;
        return `
            <div class="ingredient-pill ${ok ? 'ok' : 'short'}">
                <img src="../installation/images/${escapeHtml(ingredient.image)}" onerror="this.style.display='none'">
                <span>${escapeHtml(ingredient.label)}</span>
                <span class="ingredient-count">${ingredient.have}/${ingredient.required}</span>
            </div>
        `;
    }

    function recipeCard(tonic) {
        const craftable = tonic.ingredients.every((i) => i.have >= i.required);
        return `
            <div class="recipe-card" data-id="${escapeHtml(tonic.id)}">
                <div class="recipe-icon">
                    <img src="../installation/images/${escapeHtml(tonic.image)}" onerror="this.style.display='none'">
                </div>
                <div class="recipe-body">
                    <div class="recipe-top-row">
                        <span class="recipe-name">${escapeHtml(tonic.label)}</span>
                        <span class="recipe-time"><span class="clock">&#9201;</span>${formatDuration(tonic.durationMs)}</span>
                    </div>
                    <div class="recipe-desc">${escapeHtml(tonic.description || '')}</div>
                    <div class="ingredient-row">
                        ${tonic.ingredients.map(ingredientPill).join('')}
                    </div>
                    <div class="recipe-bottom-row">
                        <span class="output-label">Yields <b>${tonic.outputAmount}x ${escapeHtml(tonic.label)}</b></span>
                        <button class="craft-btn" ${craftable ? '' : 'disabled'} data-id="${escapeHtml(tonic.id)}">Craft</button>
                    </div>
                </div>
            </div>
        `;
    }

    function render(tonics) {
        if (!tonics || tonics.length === 0) {
            listEl.innerHTML = '<div class="empty-state">No tonic recipes are configured.</div>';
            return;
        }
        listEl.innerHTML = tonics.map(recipeCard).join('');

        listEl.querySelectorAll('.craft-btn').forEach((btn) => {
            btn.addEventListener('click', () => {
                if (btn.disabled) return;
                const id = btn.getAttribute('data-id');
                post('craftTonic', { id });
                close();
            });
        });
    }

    // Dragging - grab anywhere on the header (except the close button) and
    // move the panel with the pointer. The panel starts centered (plain flex
    // centering in CSS); the first drag switches it to an absolute
    // top/left position so it can be placed anywhere, and that position is
    // kept (not re-centered) for the rest of this UI session so a player
    // moving it out of the way of their inventory doesn't have it jump back
    // every time they open it again.
    let dragging = false;
    let dragOffsetX = 0;
    let dragOffsetY = 0;

    function clamp(value, min, max) {
        return Math.min(Math.max(value, min), max);
    }

    function placePanelAt(left, top) {
        const rect = panelEl.getBoundingClientRect();
        const maxLeft = Math.max(0, window.innerWidth - rect.width);
        const maxTop = Math.max(0, window.innerHeight - rect.height);
        panelEl.style.position = 'fixed';
        panelEl.style.margin = '0';
        panelEl.style.left = `${clamp(left, 0, maxLeft)}px`;
        panelEl.style.top = `${clamp(top, 0, maxTop)}px`;
    }

    function onDragStart(e) {
        if (e.target === closeBtn) return;
        dragging = true;
        const rect = panelEl.getBoundingClientRect();
        dragOffsetX = e.clientX - rect.left;
        dragOffsetY = e.clientY - rect.top;
        panelEl.classList.add('dragging');
        e.preventDefault();
    }

    function onDragMove(e) {
        if (!dragging) return;
        placePanelAt(e.clientX - dragOffsetX, e.clientY - dragOffsetY);
    }

    function onDragEnd() {
        if (!dragging) return;
        dragging = false;
        panelEl.classList.remove('dragging');
    }

    headerEl.addEventListener('mousedown', onDragStart);
    window.addEventListener('mousemove', onDragMove);
    window.addEventListener('mouseup', onDragEnd);

    function open(tonics) {
        render(tonics);
        appEl.classList.remove('hidden');
    }

    function close() {
        appEl.classList.add('hidden');
        post('close', {});
    }

    window.addEventListener('message', (event) => {
        const data = event.data || {};
        if (data.action === 'open') {
            open(data.tonics);
        } else if (data.action === 'close') {
            appEl.classList.add('hidden');
        }
    });

    closeBtn.addEventListener('click', close);

    document.addEventListener('keyup', (e) => {
        if (e.key === 'Escape') close();
    });
})();
