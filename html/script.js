(() => {
    const $ = (id) => document.getElementById(id);

    const app = $('app');
    const panel = document.querySelector('.beehive-panel');
    const panelHeader = document.querySelector('.panel-header');
    const views = { inactive: $('inactiveView'), active: $('activeView'), busy: $('busyView') };
    const hiveStatusLabel = $('hiveStatusLabel');
    const footerMessage = $('footerMessage');
    const upkeepNotice = $('upkeepNotice');
    const upkeepSection = $('upkeepSection');
    const panelActions = $('panelActions');
    const notOwnerNote = $('notOwnerNote');
    const pickupBtn = $('pickupBtn');
    const pickupLabel = $('pickupLabel');
    const harvestHoneyBtn = $('harvestHoneyBtn');
    const addFoodBtn = $('addFoodBtn');
    const addWaterBtn = $('addWaterBtn');
    const closeBtn = $('closeBtn');

    const REFRESH_INTERVAL_MS = 5000;
    const PICKUP_CONFIRM_MS = 3000;
    const POSITION_KEY = 'rsgBeekeeperPanelPosition';

    // Element id -> locale key. English fallback text is baked into index.html.
    const LOCALE_TARGETS = {
        panelTitle: 'panelTitle',
        inactiveFlavorText: 'inactiveFlavorText',
        addQueenLabel: 'addQueenLabel',
        addQueenSub: 'addQueenSub',
        activeFlavorText: 'activeFlavorText',
        populationLabel: 'populationLabel',
        upkeepNotice: 'upkeepNotice',
        foodLabel: 'foodLabel',
        addFoodBtn: 'addFoodBtn',
        waterLabel: 'waterLabel',
        addWaterBtn: 'addWaterBtn',
        healthLabel: 'healthLabel',
        honeyLabel: 'honeyLabel',
        harvestHoneyBtn: 'harvestHoneyBtn',
        busyFlavorText: 'busyFlavorText',
        pickupLabel: 'pickupLabel',
        pickupSub: 'pickupSub',
        notOwnerNote: 'notOwnerNote',
    };

    let strings = {
        statusActive: 'Hive Active',
        statusInactive: 'Hive Inactive',
        statusWorking: 'Working',
        pickupLabel: 'Pick Up Beehive',
        pickupConfirm: 'Click again to confirm',
    };

    let state = null;          // last hive payload from the server
    let isBusy = false;
    let refreshTimer = null;
    let pickupArmedTimer = null;
    let busyTimer = null;
    const BUSY_TIMEOUT_MS = 10000;

    const clamp = (v, min, max) => Math.max(min, Math.min(max, Number(v) || 0));

    function nuiFetch(endpoint, data) {
        const resource = (window.GetParentResourceName && window.GetParentResourceName()) || 'rsg-beekeeper';
        return fetch(`https://${resource}/${endpoint}`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json; charset=UTF-8' },
            body: JSON.stringify(data || {}),
        }).catch(() => {});
    }

    function applyLocale(incoming) {
        if (!incoming) return;
        strings = Object.assign(strings, incoming);

        for (const [elId, key] of Object.entries(LOCALE_TARGETS)) {
            if (strings[key]) $(elId).textContent = strings[key];
        }
        if (strings.closeTitle) closeBtn.title = strings.closeTitle;
        if (state) render();
    }

    // --- Rendering ----------------------------------------------------------

    function setStat(name, value, max = 100, thresholds = true) {
        value = clamp(value, 0, max);
        const pct = max > 0 ? (value / max) * 100 : 0;
        const fill = $(`${name}Fill`);

        $(`${name}Count`).textContent = max === 100 ? `${Math.round(value)}%` : `${value} / ${max}`;
        fill.style.width = `${pct}%`;

        if (thresholds) {
            fill.classList.toggle('stat-good', pct > 50);
            fill.classList.toggle('stat-warn', pct > 20 && pct <= 50);
            fill.classList.toggle('stat-bad', pct <= 20);
        }
        return value;
    }

    function showView(name) {
        Object.entries(views).forEach(([key, el]) => el.classList.toggle('hidden', key !== name));
    }

    function render() {
        if (isBusy) {
            showView('busy');
            panelActions.classList.add('hidden');
            hiveStatusLabel.textContent = strings.statusWorking;
            return;
        }

        const s = state;
        panelActions.classList.remove('hidden');
        pickupBtn.classList.toggle('hidden', !s.isOwner);
        notOwnerNote.classList.toggle('hidden', !!s.isOwner);

        if (!s.active) {
            showView('inactive');
            hiveStatusLabel.textContent = strings.statusInactive;
            return;
        }

        showView('active');
        hiveStatusLabel.textContent = strings.statusActive;

        const max = s.max || 200;
        const population = setStat('population', s.population, max, false);
        const isFull = population >= max;
        $('populationFill').classList.toggle('stat-good', isFull);
        $('populationFill').classList.toggle('stat-warn', !isFull);

        upkeepNotice.classList.toggle('hidden', isFull);
        upkeepSection.classList.toggle('hidden', !isFull);
        if (!isFull) return;

        const food = setStat('food', s.food ?? 100);
        const water = setStat('water', s.water ?? 100);
        setStat('health', s.health ?? 100);
        const honey = setStat('honey', s.honey ?? 0, 100, false);

        $('honeyFill').classList.toggle('stat-good', honey >= 100);
        $('honeyFill').classList.toggle('stat-warn', honey < 100);

        addFoodBtn.classList.toggle('hidden', food >= 100);
        addWaterBtn.classList.toggle('hidden', water >= 100);
        harvestHoneyBtn.classList.toggle('hidden', honey < 100 || !s.isOwner);
    }

    // --- Refresh loop -------------------------------------------------------

    function stopRefresh() {
        clearInterval(refreshTimer);
        refreshTimer = null;
    }

    function startRefresh() {
        stopRefresh();
        refreshTimer = setInterval(() => {
            if (state && !isBusy) nuiFetch('refreshHiveInfo', { id: state.id });
        }, REFRESH_INTERVAL_MS);
    }

    // --- Pickup confirmation -----------------------------------------------

    function disarmPickup() {
        clearTimeout(pickupArmedTimer);
        pickupArmedTimer = null;
        pickupBtn.classList.remove('armed');
        pickupLabel.textContent = strings.pickupLabel;
    }

    // --- Draggable, remembered panel position ------------------------------

    let dragState = null;

    function setPanelPosition(left, top) {
        const rect = panel.getBoundingClientRect();
        panel.style.left = `${clamp(left, 0, Math.max(0, window.innerWidth - rect.width))}px`;
        panel.style.top = `${clamp(top, 0, Math.max(0, window.innerHeight - rect.height))}px`;
    }

    function restorePanelPosition() {
        let saved = null;
        try { saved = JSON.parse(localStorage.getItem(POSITION_KEY)); } catch (e) { saved = null; }

        if (saved && typeof saved.left === 'number' && typeof saved.top === 'number') {
            setPanelPosition(saved.left, saved.top);
        } else {
            const rect = panel.getBoundingClientRect();
            setPanelPosition((window.innerWidth - rect.width) / 2, (window.innerHeight - rect.height) / 2);
        }
    }

    panelHeader.addEventListener('mousedown', (event) => {
        if (event.target.closest('button')) return;
        const rect = panel.getBoundingClientRect();
        dragState = { x: event.clientX - rect.left, y: event.clientY - rect.top };
        panel.classList.add('dragging');
        event.preventDefault();
    });

    window.addEventListener('mousemove', (event) => {
        if (dragState) setPanelPosition(event.clientX - dragState.x, event.clientY - dragState.y);
    });

    window.addEventListener('mouseup', () => {
        if (!dragState) return;
        dragState = null;
        panel.classList.remove('dragging');
        const rect = panel.getBoundingClientRect();
        try { localStorage.setItem(POSITION_KEY, JSON.stringify({ left: rect.left, top: rect.top })); } catch (e) { /* not fatal */ }
    });

    window.addEventListener('resize', () => {
        if (app.classList.contains('hidden')) return;
        const rect = panel.getBoundingClientRect();
        setPanelPosition(rect.left, rect.top);
    });

    // --- Open / close / messages -------------------------------------------

    function openUI(payload) {
        state = payload;
        isBusy = false;
        footerMessage.textContent = '';
        disarmPickup();
        app.classList.remove('hidden');
        render();
        restorePanelPosition();
        startRefresh();
    }

    function closeUI() {
        app.classList.add('hidden');
        state = null;
        isBusy = false;
        disarmPickup();
        stopRefresh();
    }

    function requestClose() {
        nuiFetch('closeBeehiveUI');
        closeUI();
    }

    function sameHive(payload) {
        return state && payload.id === state.id;
    }

    window.addEventListener('message', (event) => {
        const data = event.data || {};

        switch (data.action) {
            case 'open':
                openUI(data);
                break;
            case 'close':
                closeUI();
                break;
            case 'update':
                // Periodic refresh -- keep the footer message and position.
                if (!sameHive(data) || isBusy) return;
                state = Object.assign(state, data);
                render();
                break;
            case 'result':
                if (!sameHive(data)) return;
                isBusy = false;
                clearTimeout(busyTimer);
                if (data.success) state = Object.assign(state, data);
                footerMessage.textContent = data.message || '';
                render();
                break;
            case 'locale':
                applyLocale(data.strings);
                break;
            case 'placementShow':
                showPlacementHud(data.strings);
                break;
            case 'placementUpdate':
                updatePlacementHud(data);
                break;
            case 'placementHide':
                placeHud.classList.add('hidden');
                break;
        }
    });

    // --- Placement HUD (display only, never takes focus) -------------------

    const placeHud = $('placeHud');
    const placeHudStatus = $('placeHudStatus');
    const PLACE_HUD_TEXT = {
        placeHudTitle: 'title',
        placeHudPlace: 'place',
        placeHudRotate: 'rotate',
        placeHudHeight: 'height',
        placeHudCancel: 'cancel',
        placeHudHeadingLabel: 'headingLabel',
        placeHudHeightLabel: 'heightLabel',
    };
    let placeStrings = {};

    function showPlacementHud(incoming) {
        placeStrings = incoming || {};
        for (const [elId, key] of Object.entries(PLACE_HUD_TEXT)) {
            if (placeStrings[key]) $(elId).textContent = placeStrings[key];
        }
        updatePlacementHud({ valid: false, reason: '', heading: 0, height: 0 });
        placeHud.classList.remove('hidden');
    }

    function updatePlacementHud(data) {
        const valid = !!data.valid;
        placeHudStatus.classList.toggle('valid', valid);
        placeHudStatus.classList.toggle('invalid', !valid);
        $('placeHudReason').textContent = valid ? (placeStrings.valid || '') : (data.reason || '');
        $('placeHudHeading').textContent = `${Math.round(Number(data.heading) || 0)}°`;
        const h = Number(data.height) || 0;
        $('placeHudHeightVal').textContent = `${h > 0 ? '+' : ''}${h.toFixed(2)} m`;
    }

    // --- Actions ------------------------------------------------------------

    function sendAction(action) {
        if (isBusy || !state) return;
        isBusy = true;
        footerMessage.textContent = '';
        disarmPickup();
        render();
        nuiFetch('hiveAction', { id: state.id, action });

        // Safety net: if no reply ever arrives, don't leave the panel stuck.
        clearTimeout(busyTimer);
        busyTimer = setTimeout(() => {
            if (!isBusy || !state) return;
            isBusy = false;
            render();
            nuiFetch('refreshHiveInfo', { id: state.id });
        }, BUSY_TIMEOUT_MS);
    }

    $('addQueenBtn').addEventListener('click', () => sendAction('addQueenBee'));
    addFoodBtn.addEventListener('click', () => sendAction('addFood'));
    addWaterBtn.addEventListener('click', () => sendAction('addWater'));
    harvestHoneyBtn.addEventListener('click', () => sendAction('harvestHoney'));

    // Picking up is destructive (it ends the colony), so it needs two clicks.
    pickupBtn.addEventListener('click', () => {
        if (isBusy || !state) return;
        if (pickupArmedTimer) {
            sendAction('pickupBeehive');
            return;
        }
        pickupBtn.classList.add('armed');
        pickupLabel.textContent = strings.pickupConfirm;
        pickupArmedTimer = setTimeout(disarmPickup, PICKUP_CONFIRM_MS);
    });

    closeBtn.addEventListener('click', requestClose);

    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && !app.classList.contains('hidden')) requestClose();
    });

    // The panel can't call ox_lib's locale() itself -- ask Lua for strings.
    nuiFetch('nuiReady');
})();
