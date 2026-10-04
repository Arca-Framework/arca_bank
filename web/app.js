const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'arca_bank';
const post = (name, data = {}) =>
    fetch(`https://${RES}/${name}`, { method: 'POST', body: JSON.stringify(data) }).then((r) => r.json()).catch(() => null);
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const usd = (n) => `$${Math.floor(Number(n) || 0).toLocaleString()}`;

// ------------------------------------------------------------ toast + modal
let toastTimer;
function toast(msg, ok = true) {
    if (!msg) return;
    const t = $('#toast');
    t.textContent = msg;
    t.className = ok ? '' : 'error';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
}

let modalSubmit = null;
function modal(title, body, onSubmit, okLabel = 'Confirm') {
    $('#modal-title').textContent = title;
    $('#modal-body').innerHTML = body;
    $('#modal-ok').textContent = okLabel;
    modalSubmit = onSubmit;
    $('#modal').classList.remove('hidden');
    setTimeout(() => $('#modal-body input')?.focus(), 30);
}
function closeModal() { $('#modal').classList.add('hidden'); modalSubmit = null; }
$('#modal-box').addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!modalSubmit) return;
    // a submit handler returns 'keep' to leave the dialog open (e.g. PINs don't match)
    const keep = await modalSubmit();
    if (keep !== 'keep') closeModal();
});
$('#modal-cancel').onclick = closeModal;

// =================================================================== BANK
let bank = null;
let selected = null;

function account() { return bank.accounts.find((a) => a.ref === selected) || bank.accounts[0]; }

function renderBank() {
    $('#me-name').textContent = bank.name;
    $('#me-cid').textContent = bank.citizenid;
    $('#me-cash').textContent = usd(bank.cash);
    if (!bank.accounts.some((a) => a.ref === selected)) selected = bank.accounts[0].ref;

    $('#accounts').innerHTML = bank.accounts.map((a) => `
        <button class="acc${a.ref === selected ? ' on' : ''}" data-ref="${esc(a.ref)}">
            <span class="ic"><i class="${esc(a.icon)}"></i></span>
            <span class="t"><strong>${esc(a.label)}</strong><small>${a.kind === 'personal' ? 'Personal' : a.kind === 'job' ? 'Job account' : `#${esc(a.number)}`}${a.card ? ' · <i class="fa-solid fa-credit-card"></i>' : ''}</small></span>
            <span class="b">${usd(a.balance)}</span>
        </button>`).join('');

    const btn = $('#open-account');
    btn.disabled = bank.owned >= bank.maxAccounts;
    btn.innerHTML = `<i class="fa-solid fa-plus"></i> Open an account (${bank.owned}/${bank.maxAccounts})`;

    const a = account();
    const pill = $('#acc-kind');
    pill.textContent = a.kind === 'personal' ? 'Personal' : a.kind === 'job' ? `Job · ${a.job}` : a.kind;
    pill.className = `pill ${a.kind}`;
    $('#acc-label').textContent = a.label;
    $('#acc-number').textContent = a.kind === 'personal' ? a.number : `#${a.number}`;
    $('#acc-card').innerHTML = a.card ? '· <i class="fa-solid fa-credit-card"></i> Card active' : '· No card';
    $('#acc-balance').textContent = usd(a.balance);
    $('#pin-label').textContent = a.card ? 'Change PIN' : 'Set card PIN';
    $('#tab-manage').classList.toggle('hidden', a.access !== 'manage');
    if (a.access !== 'manage') showTab('activity');
    renderManage(a);
}

async function loadTx() {
    const list = await post('transactions', { ref: selected }) || [];
    $('#tx').innerHTML = list.length ? list.map((t) => {
        const incoming = t.amount > 0;
        const d = new Date(typeof t.created_at === 'number' ? t.created_at : String(t.created_at).replace(' ', 'T'));
        return `<div class="tx-row"><span class="ic ${incoming ? 'in' : 'out'}"><i class="fa-solid ${t.kind === 'transfer' ? 'fa-right-left' : incoming ? 'fa-arrow-down' : 'fa-arrow-up'}"></i></span>
            <span class="t"><strong>${esc(t.description)}</strong><small>${d.toLocaleString(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}${t.actor ? ' · ' + esc(t.actor) : ''}</small></span>
            <span class="amt ${incoming ? 'in' : ''}">${incoming ? '+' : '−'}${usd(Math.abs(t.amount))}<small>${usd(t.balance)}</small></span></div>`;
    }).join('') : '<div class="empty"><i class="fa-solid fa-receipt"></i>No activity yet</div>';
}

function renderManage(a) {
    if (a.access !== 'manage') { $('#manage').innerHTML = ''; return; }
    const members = a.members || [];
    $('#manage').innerHTML = `<div class="manage-grid">
        <div class="box"><h4>Account name</h4><div class="row-form"><input class="field" id="m-label" maxlength="40" value="${esc(a.label)}"><button class="primary" data-m="rename">Save</button></div></div>
        <div class="box"><h4>Give access</h4><div class="row-form"><input class="field" id="m-cid" placeholder="Citizen ID"><button class="primary" data-m="add">Add</button></div>
            <p class="note" style="margin-top:8px">They can deposit, withdraw and transfer. Only you can manage the account.</p></div>
        <div class="box"><h4>People with access (${members.length})</h4>${members.length ? members.map((m) => `<div class="member"><span>${esc(m.name)}</span><small>${esc(m.citizenid)}</small><button data-m="remove" data-cid="${esc(m.citizenid)}">Remove</button></div>`).join('') : '<p class="note">Only you.</p>'}</div>
        <div class="box"><h4>Close account</h4><p class="note" style="margin-bottom:10px">The balance (${usd(a.balance)}) moves to your personal account.</p><button class="danger" data-m="close">Close account</button></div>
    </div>`;
}

async function bankCall(name, payload) {
    const res = await post(name, { ref: selected, ...payload });
    if (!res) return false;
    toast(res.msg, res.ok);
    if (res.data) { bank = res.data; renderBank(); loadTx(); }
    return res.ok;
}

function showTab(name) {
    $$('.tabs button').forEach((b) => b.classList.toggle('on', b.dataset.tab === name));
    $$('.pane').forEach((p) => p.classList.toggle('on', p.dataset.pane === name));
}

const amountField = (id = 'f-amount') => `<label><span>Amount</span><input class="field" id="${id}" type="number" min="1" placeholder="0"></label>
    <div class="amounts">${[100, 500, 1000, 5000].map((n) => `<button type="button" data-fill="${n}">${usd(n)}</button>`).join('')}</div>`;
$('#modal-body').addEventListener('click', (e) => {
    const b = e.target.closest('[data-fill]');
    if (b) $('#f-amount').value = b.dataset.fill;
    const t = e.target.closest('[data-type]');
    if (t) { $$('.types button').forEach((x) => x.classList.toggle('on', x === t)); }
});

const ACTIONS = {
    deposit: () => modal(`Deposit to ${account().label}`, `<p class="note">Cash on hand: ${usd(bank.cash)}</p>${amountField()}`,
        () => bankCall('deposit', { amount: Number($('#f-amount').value) }), 'Deposit'),
    withdraw: () => modal(`Withdraw from ${account().label}`, `<p class="note">Balance: ${usd(account().balance)}</p>${amountField()}`,
        () => bankCall('withdraw', { amount: Number($('#f-amount').value) }), 'Withdraw'),
    transfer: () => modal(`Transfer from ${account().label}`, `
        <label><span>To (citizen ID or account number)</span><input class="field" id="f-target" placeholder="ABC12345 or 1001"></label>
        ${amountField()}
        <label><span>Note (optional)</span><input class="field" id="f-note" maxlength="60" placeholder="Rent"></label>
        ${bank.accounts.length > 1 ? `<div class="amounts">${bank.accounts.filter((x) => x.ref !== selected).map((x) => `<button type="button" data-own="${esc(x.kind === 'personal' ? x.number : x.number)}">→ ${esc(x.label)}</button>`).join('')}</div>` : ''}`,
        () => bankCall('transfer', { target: $('#f-target').value, amount: Number($('#f-amount').value), note: $('#f-note').value }), 'Send'),
    pin: () => modal(account().card ? 'Change card PIN' : 'Set card PIN', `
        <p class="note">A ${bank.pinLength}-digit PIN turns this account into a card you can use at any ATM.</p>
        <label><span>New PIN</span><input class="field" id="f-pin" type="password" inputmode="numeric" maxlength="${bank.pinLength}" placeholder="${'•'.repeat(bank.pinLength)}"></label>
        <label><span>Repeat PIN</span><input class="field" id="f-pin2" type="password" inputmode="numeric" maxlength="${bank.pinLength}"></label>`,
        async () => {
            const a = $('#f-pin').value, b = $('#f-pin2').value;
            if (a !== b) { toast('The PINs don\'t match', false); return 'keep'; }
            return bankCall('setPin', { pin: a });
        }, 'Save PIN'),
};
$('#modal-body').addEventListener('click', (e) => {
    const own = e.target.closest('[data-own]');
    if (own) $('#f-target').value = own.dataset.own;
});

$('.actions').addEventListener('click', (e) => {
    const b = e.target.closest('[data-do]');
    if (b && ACTIONS[b.dataset.do]) ACTIONS[b.dataset.do]();
});
$('#accounts').addEventListener('click', (e) => {
    const b = e.target.closest('[data-ref]');
    if (!b) return;
    selected = b.dataset.ref;
    renderBank();
    loadTx();
});
$('.tabs').addEventListener('click', (e) => { const b = e.target.closest('[data-tab]'); if (b) showTab(b.dataset.tab); });
$('#manage').addEventListener('click', (e) => {
    const b = e.target.closest('[data-m]');
    if (!b) return;
    if (b.dataset.m === 'rename') bankCall('rename', { label: $('#m-label').value });
    if (b.dataset.m === 'add') bankCall('addMember', { citizenid: $('#m-cid').value });
    if (b.dataset.m === 'remove') bankCall('removeMember', { citizenid: b.dataset.cid });
    if (b.dataset.m === 'close') modal('Close this account?', `<p class="note">${esc(account().label)} will be closed. ${usd(account().balance)} moves to your personal account.</p>`, () => bankCall('closeAccount'), 'Close account');
});
$('#open-account').addEventListener('click', () => {
    modal('Open a new account', `
        <label><span>Account name</span><input class="field" id="f-label" maxlength="40" placeholder="Rainy day fund"></label>
        <div class="types">${bank.types.map((t, i) => `<button type="button" data-type="${esc(t.id)}" class="${i === 0 ? 'on' : ''}"><i class="${esc(t.icon)}"></i>${esc(t.label)}</button>`).join('')}</div>`,
        async () => {
            const kind = $('.types button.on')?.dataset.type;
            const ok = await post('create', { label: $('#f-label').value, kind });
            if (!ok) return;
            toast(ok.msg, ok.ok);
            if (ok.data) { bank = ok.data; selected = bank.accounts[bank.accounts.length - 1].ref; renderBank(); loadTx(); }
        }, 'Open account');
});
$('#bank-close').onclick = () => post('close');

// =================================================================== ATM
let atm = null;
let atmCard = null;
let pin = '';
const scr = $('#atm-screen');

function atmCards() {
    scr.innerHTML = `<h2>Choose a card</h2><p class="sub">Cash on hand ${usd(atm.cash)}</p><div class="card-pick">
        ${atm.cards.map((c) => `<button class="cardbtn" data-card="${esc(c.ref)}" ${c.card ? '' : 'disabled'}>
            <span class="chip"></span><span class="t"><strong>${esc(c.label)}</strong><small>${c.card ? (c.kind === 'personal' ? esc(c.number) : '#' + esc(c.number)) : 'No card · set a PIN at any Fleeca branch'}</small></span>
            ${c.card ? '<i class="fa-solid fa-chevron-right"></i>' : '<i class="fa-solid fa-lock"></i>'}</button>`).join('')}
    </div><button class="back-link" data-atm="exit">Take card and leave</button>`;
}
function atmPin(err = '') {
    scr.innerHTML = `<h2>${esc(atmCard.label)}</h2><p class="sub">Enter your ${atm.pinLength}-digit PIN</p>
        <div class="dots">${Array.from({ length: atm.pinLength }, (_, i) => `<i class="${i < pin.length ? 'on' : ''}"></i>`).join('')}</div>
        <div class="err">${esc(err)}</div>
        <div class="pad">${[1, 2, 3, 4, 5, 6, 7, 8, 9].map((n) => `<button data-pin="${n}">${n}</button>`).join('')}
            <button class="clr" data-pin="clr">Clear</button><button data-pin="0">0</button><button class="ok" data-pin="ok">Enter</button></div>
        <button class="back-link" data-atm="cards">Back</button>`;
}
function atmMenu(balance, err = '') {
    scr.innerHTML = `<div class="atm-bal"><small>${esc(atmCard.label)}</small><b>${usd(balance)}</b></div>
        <div class="err">${esc(err)}</div>
        <div class="quick">${atm.quick.map((n) => `<button data-wd="${n}">${usd(n)}</button>`).join('')}<button data-wd="custom">Other</button></div>
        <p class="sub" style="text-align:center">Max ${usd(atm.max)} per withdrawal</p>
        <button class="back-link" data-atm="cards">Use another card</button>`;
    atmCard.balance = balance;
}

async function submitPin() {
    if (pin.length !== atm.pinLength) return;
    const res = await post('atmUnlock', { ref: atmCard.ref, pin });
    pin = '';
    if (!res || !res.ok) return atmPin(res ? res.msg : 'Error');
    atmMenu(res.balance);
}
async function withdraw(amount) {
    const res = await post('atmWithdraw', { ref: atmCard.ref, amount });
    if (!res) return;
    if (res.ok) { toast(res.msg); atm.cash += amount; atmMenu(res.balance); } else atmMenu(atmCard.balance, res.msg);
}

scr.addEventListener('click', (e) => {
    const card = e.target.closest('[data-card]');
    if (card) { atmCard = atm.cards.find((c) => c.ref === card.dataset.card); pin = ''; return atmPin(); }
    const p = e.target.closest('[data-pin]');
    if (p) {
        const v = p.dataset.pin;
        if (v === 'ok') return submitPin();
        if (v === 'clr') pin = '';
        else if (pin.length < atm.pinLength) pin += v;
        atmPin();
        if (pin.length === atm.pinLength) submitPin();
        return;
    }
    const wd = e.target.closest('[data-wd]');
    if (wd) {
        if (wd.dataset.wd === 'custom') {
            return modal('Withdraw', amountField(), () => withdraw(Number($('#f-amount').value)), 'Withdraw');
        }
        return withdraw(Number(wd.dataset.wd));
    }
    const nav = e.target.closest('[data-atm]');
    if (nav?.dataset.atm === 'cards') return atmCards();
    if (nav?.dataset.atm === 'exit') return post('close');
});
$('#atm-close').onclick = () => post('close');

// ------------------------------------------------------------ messages + keys
window.addEventListener('message', ({ data }) => {
    if (data.action === 'bank') {
        bank = data.data;
        selected = bank.accounts[0].ref;
        $('#atm').classList.add('hidden');
        $('#bank').classList.remove('hidden');
        showTab('activity');
        renderBank();
        loadTx();
    } else if (data.action === 'atm') {
        atm = data.data;
        $('#bank').classList.add('hidden');
        $('#atm').classList.remove('hidden');
        atmCards();
    } else if (data.action === 'close') {
        $('#bank').classList.add('hidden');
        $('#atm').classList.add('hidden');
        closeModal();
    }
});

document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
        if (!$('#modal').classList.contains('hidden')) return closeModal();
        return post('close');
    }
    // type the PIN on the keyboard
    if (!$('#atm').classList.contains('hidden') && atmCard && $('.pad') && $('#modal').classList.contains('hidden')) {
        if (/^\d$/.test(e.key) && pin.length < atm.pinLength) { pin += e.key; atmPin(); if (pin.length === atm.pinLength) submitPin(); }
        if (e.key === 'Backspace') { pin = pin.slice(0, -1); atmPin(); }
        if (e.key === 'Enter') submitPin();
    }
});
