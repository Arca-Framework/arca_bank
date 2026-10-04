-- arca_bank: accounts, access, cards (PINs), transactions, branches, ATMs and the phone app.
--
-- Account references ("refs") used everywhere, including exports:
--   'p:<citizenid>'  personal account: this IS the arca_core 'bank' balance, so every script
--                    using player.AddMoney('bank', ...) keeps working
--   'a:<id>'         an extra account (savings / shared / business) or a job account
--   'job:<name>'     shortcut for a job's account

local cfg = BankConfig
local Accounts = {}     -- [id] = { id, kind, label, owner, ownerName, job, balance, members = { [cid] = name } }
local JobAccount = {}   -- [job] = id
local Pins = {}         -- [ref] = pin hash
local pinFails = {}     -- [src..ref] = { count, lockedUntil }
local atmUnlocked = {}  -- [src] = { [ref] = expires }
local selfChange = false -- true while we move a personal balance ourselves (so it isn't logged twice)

local function notify(src, msg, kind) TriggerClientEvent('arca_core:notify', src, msg, kind or 'inform') end
local function getPlayer(src) return exports.arca_core:GetPlayer(src) end
local function fullName(player) local c = player.PlayerData.charinfo return ('%s %s'):format(c.firstname, c.lastname) end
local function money(n) return math.floor(tonumber(n) or 0) end

---------------------------------------------------------------------
-- Database
---------------------------------------------------------------------
local function setupDatabase()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `arca_bank_accounts` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `kind` VARCHAR(20) NOT NULL,
            `label` VARCHAR(50) NOT NULL,
            `owner` VARCHAR(50) NULL,
            `owner_name` VARCHAR(100) NULL,
            `job` VARCHAR(50) NULL,
            `balance` BIGINT NOT NULL DEFAULT 0,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), KEY `owner` (`owner`), UNIQUE KEY `job` (`job`)
        ) ENGINE=InnoDB AUTO_INCREMENT=1000 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `arca_bank_members` (
            `account_id` INT NOT NULL,
            `citizenid` VARCHAR(50) NOT NULL,
            `name` VARCHAR(100) NOT NULL,
            PRIMARY KEY (`account_id`, `citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `arca_bank_pins` (
            `ref` VARCHAR(60) NOT NULL,
            `pin` VARCHAR(20) NOT NULL,
            PRIMARY KEY (`ref`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `arca_bank_transactions` (
            `id` INT NOT NULL AUTO_INCREMENT,
            `ref` VARCHAR(60) NOT NULL,
            `kind` VARCHAR(20) NOT NULL,
            `amount` BIGINT NOT NULL,
            `balance` BIGINT NOT NULL,
            `description` VARCHAR(120) NOT NULL,
            `actor` VARCHAR(100) NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (`id`), KEY `ref` (`ref`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
end

local function loadAll()
    for _, row in ipairs(MySQL.query.await('SELECT * FROM arca_bank_accounts') or {}) do
        Accounts[row.id] = { id = row.id, kind = row.kind, label = row.label, owner = row.owner, ownerName = row.owner_name, job = row.job, balance = row.balance, members = {} }
        if row.job then JobAccount[row.job] = row.id end
    end
    for _, row in ipairs(MySQL.query.await('SELECT * FROM arca_bank_members') or {}) do
        if Accounts[row.account_id] then Accounts[row.account_id].members[row.citizenid] = row.name end
    end
    for _, row in ipairs(MySQL.query.await('SELECT * FROM arca_bank_pins') or {}) do Pins[row.ref] = row.pin end

    -- every job with bank = { minGrade } in arca_core/shared/jobs.lua gets an account
    for name, job in pairs(exports.arca_core:GetJobs() or {}) do
        if type(job.bank) == 'table' and not JobAccount[name] then
            local id = MySQL.insert.await('INSERT INTO arca_bank_accounts (kind, label, job) VALUES (?, ?, ?)', { 'job', job.label or name, name })
            Accounts[id] = { id = id, kind = 'job', label = job.label or name, job = name, balance = 0, members = {} }
            JobAccount[name] = id
        end
    end
end

---------------------------------------------------------------------
-- Refs, access, balances
---------------------------------------------------------------------
local function parseRef(ref)
    if type(ref) == 'number' then return 'a', ref end
    ref = tostring(ref or '')
    local kind, rest = ref:match('^(%a+):(.+)$')
    if kind == 'p' then return 'p', rest end
    if kind == 'a' then return 'a', tonumber(rest) end
    if kind == 'job' then return 'a', JobAccount[rest] end
    return nil
end

local function normRef(ref)
    local kind, key = parseRef(ref)
    if kind == 'p' then return 'p:' .. key end
    if kind == 'a' and key and Accounts[key] then return 'a:' .. key end
end

local function jobMinGrade(jobName)
    local job = (exports.arca_core:GetJobs() or {})[jobName]
    return job and type(job.bank) == 'table' and (job.bank.minGrade or 0) or nil
end

---What a player may do with an account: nil (nothing), 'use' or 'manage'
local function accessOf(player, ref)
    local kind, key = parseRef(ref)
    local cid = player.PlayerData.citizenid
    if kind == 'p' then return key == cid and 'personal' or nil end
    local acc = kind == 'a' and Accounts[key]
    if not acc then return nil end
    if acc.kind == 'job' then
        -- any job they hold counts (multi-job), not only the active one
        local min = jobMinGrade(acc.job)
        local heldJobs = player.PlayerData.metadata.jobs or {}
        local grade = heldJobs[acc.job]
        if grade == nil and player.PlayerData.job.name == acc.job then grade = player.PlayerData.job.grade.level end
        return (min and grade and grade >= min) and 'use' or nil
    end
    if acc.owner == cid then return 'manage' end
    if acc.members[cid] then return 'use' end
end

local function personalOnline(cid)
    return exports.arca_core:GetPlayerByCitizenId(cid)
end

local function balanceOf(ref)
    local kind, key = parseRef(ref)
    if kind == 'p' then
        local p = personalOnline(key)
        if p then return p.PlayerData.money.bank or 0 end
        local raw = MySQL.scalar.await('SELECT money FROM players WHERE citizenid = ?', { key })
        local m = raw and json.decode(raw)
        return m and m.bank or 0
    end
    local acc = kind == 'a' and Accounts[key]
    return acc and acc.balance or nil
end

local function logTx(ref, kind, amount, balance, description, actor)
    MySQL.insert('INSERT INTO arca_bank_transactions (ref, kind, amount, balance, description, actor) VALUES (?, ?, ?, ?, ?, ?)', {
        ref, kind, amount, balance, tostring(description or ''):sub(1, 120), actor,
    })
end

---Adds (positive) or removes (negative) money from an account. Returns true on success.
local function change(ref, delta, description, actor, kind)
    ref = normRef(ref)
    delta = money(delta)
    if not ref or delta == 0 then return false end
    local k, key = parseRef(ref)
    local newBalance
    if k == 'p' then
        local p = personalOnline(key)
        if p then
            selfChange = true
            local ok = delta > 0 and p.AddMoney('bank', delta, description) or p.RemoveMoney('bank', -delta, description)
            selfChange = false
            if not ok then return false end
            -- the player object we got is a copy: read the new balance fresh
            newBalance = personalOnline(key).PlayerData.money.bank
        else
            -- offline: only deposits (transfers in) are allowed
            if delta < 0 then return false end
            local affected = MySQL.update.await("UPDATE players SET money = JSON_SET(money, '$.bank', JSON_EXTRACT(money, '$.bank') + ?) WHERE citizenid = ?", { delta, key })
            if not affected or affected == 0 then return false end
            newBalance = balanceOf(ref)
        end
    else
        local acc = Accounts[key]
        if acc.balance + delta < 0 then return false end
        acc.balance = acc.balance + delta
        newBalance = acc.balance
        MySQL.update('UPDATE arca_bank_accounts SET balance = ? WHERE id = ?', { acc.balance, acc.id })
    end
    logTx(ref, kind or (delta > 0 and 'deposit' or 'withdraw'), delta, newBalance, description, actor)
    return true
end

---------------------------------------------------------------------
-- Account lists for the UIs
---------------------------------------------------------------------
local TYPE_LABEL = {}
for _, t in ipairs(cfg.AccountTypes) do TYPE_LABEL[t.id] = t end

local function describe(player, ref, access)
    local k, key = parseRef(ref)
    if k == 'p' then
        return {
            ref = ref, kind = 'personal', label = 'Personal account', number = player.PlayerData.citizenid,
            balance = player.PlayerData.money.bank or 0, access = 'personal', card = Pins[ref] ~= nil,
            icon = 'fa-solid fa-user',
        }
    end
    local acc = Accounts[key]
    local members = {}
    for cid, name in pairs(acc.members) do members[#members + 1] = { citizenid = cid, name = name } end
    table.sort(members, function(a, b) return a.name < b.name end)
    return {
        ref = ref, kind = acc.kind, label = acc.label, number = tostring(acc.id), balance = acc.balance,
        access = access, card = Pins[ref] ~= nil, owner = acc.ownerName, job = acc.job,
        members = access == 'manage' and members or nil,
        icon = acc.kind == 'job' and 'fa-solid fa-building' or (TYPE_LABEL[acc.kind] or {}).icon or 'fa-solid fa-wallet',
    }
end

local function accountsFor(player)
    local cid = player.PlayerData.citizenid
    local list = { describe(player, 'p:' .. cid, 'personal') }
    for id in pairs(Accounts) do
        local ref = 'a:' .. id
        local access = accessOf(player, ref)
        if access then list[#list + 1] = describe(player, ref, access) end
    end
    table.sort(list, function(a, b)
        if a.kind == 'personal' then return true end
        if b.kind == 'personal' then return false end
        return a.label < b.label
    end)
    return list
end

local function ownedCount(cid)
    local n = 0
    for _, acc in pairs(Accounts) do if acc.owner == cid then n = n + 1 end end
    return n
end

---------------------------------------------------------------------
-- Where the player is
---------------------------------------------------------------------
local function atBranch(src)
    local pos = GetEntityCoords(GetPlayerPed(tostring(src)))
    for _, b in ipairs(cfg.Branches) do
        if #(pos - vector3(b.ped.x, b.ped.y, b.ped.z)) <= cfg.BranchRange + 2.0 then return true end
    end
    return false
end

---------------------------------------------------------------------
-- PINs
---------------------------------------------------------------------
local function hashPin(ref, pin) return tostring(joaat(('arca_bank:%s:%s'):format(ref, pin))) end
local function validPin(pin) return type(pin) == 'string' and #pin == cfg.PinLength and pin:match('^%d+$') ~= nil end

local function setPin(ref, pin)
    if not validPin(pin) then return false end
    Pins[ref] = hashPin(ref, pin)
    MySQL.query('INSERT INTO arca_bank_pins (ref, pin) VALUES (?, ?) ON DUPLICATE KEY UPDATE pin = VALUES(pin)', { ref, Pins[ref] })
    return true
end

---------------------------------------------------------------------
-- Shared operations (used by bank, ATM and phone)
---------------------------------------------------------------------
local function resolveTarget(target)
    target = tostring(target or ''):gsub('%s', ''):upper()
    if target == '' then return nil end
    -- an account number
    if target:match('^%d+$') and Accounts[tonumber(target)] then return 'a:' .. tonumber(target), Accounts[tonumber(target)].label end
    -- a citizen ID (their personal account)
    local p = personalOnline(target)
    if p then return 'p:' .. target, fullName(p) end
    local row = MySQL.single.await('SELECT charinfo FROM players WHERE citizenid = ?', { target })
    if row then
        local c = json.decode(row.charinfo or '{}') or {}
        return 'p:' .. target, ('%s %s'):format(c.firstname or '?', c.lastname or '')
    end
end

local function transfer(player, fromRef, target, amount, note)
    amount = money(amount)
    if amount <= 0 then return false, 'Enter an amount' end
    if not accessOf(player, fromRef) then return false, 'No access to that account' end
    local toRef, toName = resolveTarget(target)
    if not toRef then return false, 'No account or citizen with that number' end
    if normRef(toRef) == normRef(fromRef) then return false, 'That\'s the same account' end
    if (balanceOf(fromRef) or 0) < amount then return false, 'Not enough money' end
    local actor = fullName(player)
    note = tostring(note or ''):sub(1, 60)
    if not change(fromRef, -amount, ('Transfer to %s%s'):format(toName, note ~= '' and (' · ' .. note) or ''), actor, 'transfer') then
        return false, 'Transfer failed'
    end
    if not change(toRef, amount, ('Transfer from %s%s'):format(actor, note ~= '' and (' · ' .. note) or ''), actor, 'transfer') then
        change(fromRef, amount, 'Transfer refund', actor, 'refund') -- put it back
        return false, 'Transfer failed'
    end
    -- tell the receiver if they're online
    local k, key = parseRef(toRef)
    local receiver = k == 'p' and personalOnline(key)
    if receiver then notify(receiver.PlayerData.source, ('You received $%s from %s'):format(amount, actor), 'success') end
    return true, ('Sent $%s to %s'):format(amount, toName)
end

---------------------------------------------------------------------
-- Bank (branches)
---------------------------------------------------------------------
local function bankPayload(player)
    return {
        accounts = accountsFor(player),
        citizenid = player.PlayerData.citizenid,
        name = fullName(player),
        cash = player.PlayerData.money.cash or 0,
        types = cfg.AccountTypes,
        maxAccounts = cfg.MaxAccountsPerPlayer,
        owned = ownedCount(player.PlayerData.citizenid),
        pinLength = cfg.PinLength,
    }
end

---Every bank action: checks location + access, runs fn, returns { ok, msg, data }
local function bankAction(src, fn)
    local player = getPlayer(src)
    if not player then return { ok = false, msg = 'Not logged in' } end
    if not atBranch(src) then return { ok = false, msg = 'Visit a bank branch' } end
    local ok, msg = fn(player)
    -- fresh copy: balances and cash changed during fn
    return { ok = ok ~= false, msg = msg, data = bankPayload(getPlayer(src) or player) }
end

Arca.Callback.Register('arca_bank:open', function(src)
    local player = getPlayer(src)
    if not player or not atBranch(src) then return nil end
    return bankPayload(player)
end)

Arca.Callback.Register('arca_bank:transactions', function(src, ref)
    local player = getPlayer(src)
    ref = normRef(ref)
    if not player or not ref or not accessOf(player, ref) then return {} end
    return MySQL.query.await('SELECT kind, amount, balance, description, actor, created_at FROM arca_bank_transactions WHERE ref = ? ORDER BY id DESC LIMIT 50', { ref }) or {}
end)

Arca.Callback.Register('arca_bank:deposit', function(src, ref, amount)
    return bankAction(src, function(player)
        amount = money(amount)
        if amount <= 0 then return false, 'Enter an amount' end
        if not accessOf(player, ref) then return false, 'No access' end
        if not player.RemoveMoney('cash', amount, 'bank deposit') then return false, 'Not enough cash' end
        if not change(ref, amount, 'Cash deposit', fullName(player), 'deposit') then
            player.AddMoney('cash', amount, 'bank deposit refund')
            return false, 'Deposit failed'
        end
        return true, ('Deposited $%s'):format(amount)
    end)
end)

Arca.Callback.Register('arca_bank:withdraw', function(src, ref, amount)
    return bankAction(src, function(player)
        amount = money(amount)
        if amount <= 0 then return false, 'Enter an amount' end
        if not accessOf(player, ref) then return false, 'No access' end
        if not change(ref, -amount, 'Cash withdrawal', fullName(player), 'withdraw') then return false, 'Not enough money' end
        player.AddMoney('cash', amount, 'bank withdrawal')
        return true, ('Withdrew $%s'):format(amount)
    end)
end)

Arca.Callback.Register('arca_bank:transfer', function(src, ref, target, amount, note)
    return bankAction(src, function(player) return transfer(player, ref, target, amount, note) end)
end)

Arca.Callback.Register('arca_bank:create', function(src, label, kind)
    return bankAction(src, function(player)
        local cid = player.PlayerData.citizenid
        if not TYPE_LABEL[kind] then return false, 'Pick an account type' end
        label = tostring(label or ''):gsub('^%s+', ''):gsub('%s+$', ''):sub(1, 40)
        if label == '' then return false, 'Give the account a name' end
        if ownedCount(cid) >= cfg.MaxAccountsPerPlayer then return false, ('You can own up to %d extra accounts'):format(cfg.MaxAccountsPerPlayer) end
        local id = MySQL.insert.await('INSERT INTO arca_bank_accounts (kind, label, owner, owner_name) VALUES (?, ?, ?, ?)', { kind, label, cid, fullName(player) })
        Accounts[id] = { id = id, kind = kind, label = label, owner = cid, ownerName = fullName(player), balance = 0, members = {} }
        return true, ('Opened %s (#%d)'):format(label, id)
    end)
end)

local function managed(player, ref)
    local k, key = parseRef(ref)
    if k ~= 'a' or not Accounts[key] then return nil end
    if accessOf(player, ref) ~= 'manage' then return nil end
    return Accounts[key]
end

Arca.Callback.Register('arca_bank:rename', function(src, ref, label)
    return bankAction(src, function(player)
        local acc = managed(player, ref)
        if not acc then return false, 'Only the owner can do that' end
        label = tostring(label or ''):sub(1, 40)
        if label == '' then return false, 'Enter a name' end
        acc.label = label
        MySQL.update('UPDATE arca_bank_accounts SET label = ? WHERE id = ?', { label, acc.id })
        return true, 'Account renamed'
    end)
end)

Arca.Callback.Register('arca_bank:addMember', function(src, ref, citizenid)
    return bankAction(src, function(player)
        local acc = managed(player, ref)
        if not acc then return false, 'Only the owner can do that' end
        citizenid = tostring(citizenid or ''):gsub('%s', ''):upper()
        if citizenid == acc.owner then return false, 'You already own this account' end
        local count = 0
        for _ in pairs(acc.members) do count = count + 1 end
        if count >= cfg.MaxMembers then return false, 'This account is full' end
        local target, name = resolveTarget(citizenid)
        if not target or not target:match('^p:') then return false, 'No citizen with that ID' end
        acc.members[citizenid] = name
        MySQL.query('INSERT IGNORE INTO arca_bank_members (account_id, citizenid, name) VALUES (?, ?, ?)', { acc.id, citizenid, name })
        local p = personalOnline(citizenid)
        if p then notify(p.PlayerData.source, ('%s gave you access to "%s"'):format(fullName(player), acc.label), 'success') end
        return true, ('%s can now use this account'):format(name)
    end)
end)

Arca.Callback.Register('arca_bank:removeMember', function(src, ref, citizenid)
    return bankAction(src, function(player)
        local acc = managed(player, ref)
        if not acc then return false, 'Only the owner can do that' end
        acc.members[citizenid] = nil
        MySQL.query('DELETE FROM arca_bank_members WHERE account_id = ? AND citizenid = ?', { acc.id, citizenid })
        return true, 'Access removed'
    end)
end)

Arca.Callback.Register('arca_bank:close', function(src, ref)
    return bankAction(src, function(player)
        local acc = managed(player, ref)
        if not acc then return false, 'Only the owner can close it' end
        -- whatever is left goes to the owner's personal account
        if acc.balance > 0 then
            change('p:' .. player.PlayerData.citizenid, acc.balance, ('Closed account %s'):format(acc.label), fullName(player), 'transfer')
        end
        local r = 'a:' .. acc.id
        Accounts[acc.id] = nil
        Pins[r] = nil
        MySQL.query('DELETE FROM arca_bank_accounts WHERE id = ?', { acc.id })
        MySQL.query('DELETE FROM arca_bank_members WHERE account_id = ?', { acc.id })
        MySQL.query('DELETE FROM arca_bank_pins WHERE ref = ?', { r })
        return true, 'Account closed'
    end)
end)

Arca.Callback.Register('arca_bank:setPin', function(src, ref, pin)
    return bankAction(src, function(player)
        ref = normRef(ref)
        local access = ref and accessOf(player, ref)
        if not access then return false, 'No access' end
        -- personal + owned accounts: the owner sets the card PIN; job accounts: any member
        if access == 'use' and not ref:match('^a:') then return false, 'No access' end
        if not setPin(ref, pin) then return false, ('PIN must be %d digits'):format(cfg.PinLength) end
        return true, 'Card PIN set · it now works at ATMs'
    end)
end)

---------------------------------------------------------------------
-- ATMs: cards (accounts with a PIN), PIN check, withdrawals
---------------------------------------------------------------------
Arca.Callback.Register('arca_bank:atm', function(src)
    local player = getPlayer(src)
    if not player then return nil end
    local list = {}
    for _, acc in ipairs(accountsFor(player)) do
        list[#list + 1] = { ref = acc.ref, label = acc.label, number = acc.number, kind = acc.kind, card = acc.card, icon = acc.icon }
    end
    return { cards = list, cash = player.PlayerData.money.cash or 0, quick = cfg.AtmQuickAmounts, max = cfg.AtmMaxWithdraw, pinLength = cfg.PinLength }
end)

Arca.Callback.Register('arca_bank:atmUnlock', function(src, ref, pin)
    local player = getPlayer(src)
    ref = normRef(ref)
    if not player or not ref or not accessOf(player, ref) then return { ok = false, msg = 'No access' } end
    if not Pins[ref] then return { ok = false, msg = 'No card PIN set · visit a branch' } end
    local key = src .. ref
    local f = pinFails[key]
    if f and f.lockedUntil and f.lockedUntil > os.time() then
        return { ok = false, msg = ('Card locked · try again in %ds'):format(f.lockedUntil - os.time()) }
    end
    if hashPin(ref, tostring(pin or '')) ~= Pins[ref] then
        f = f or { count = 0 }
        f.count = f.count + 1
        if f.count >= cfg.PinAttempts then f.lockedUntil, f.count = os.time() + cfg.PinLockTime, 0 end
        pinFails[key] = f
        return { ok = false, msg = f.lockedUntil and 'Too many attempts · card locked' or ('Wrong PIN (%d left)'):format(cfg.PinAttempts - f.count) }
    end
    pinFails[key] = nil
    atmUnlocked[src] = atmUnlocked[src] or {}
    atmUnlocked[src][ref] = os.time() + 300
    return { ok = true, balance = balanceOf(ref) }
end)

Arca.Callback.Register('arca_bank:atmWithdraw', function(src, ref, amount)
    local player = getPlayer(src)
    ref = normRef(ref)
    amount = money(amount)
    local unlocked = atmUnlocked[src] and ref and atmUnlocked[src][ref]
    if not player or not unlocked or unlocked < os.time() then return { ok = false, msg = 'Enter your PIN again' } end
    if not accessOf(player, ref) then return { ok = false, msg = 'No access' } end
    if amount <= 0 or amount > cfg.AtmMaxWithdraw then return { ok = false, msg = ('Between $1 and $%s'):format(cfg.AtmMaxWithdraw) } end
    if not change(ref, -amount, 'ATM withdrawal', fullName(player), 'withdraw') then return { ok = false, msg = 'Not enough money' } end
    player.AddMoney('cash', amount, 'ATM withdrawal')
    return { ok = true, msg = ('Withdrew $%s'):format(amount), balance = balanceOf(ref) }
end)

---------------------------------------------------------------------
-- Phone (Fleeca app in arca_phone): view + transfer, no account management
---------------------------------------------------------------------
Arca.Callback.Register('arca_bank:phone', function(src)
    local player = getPlayer(src)
    if not player then return nil end
    local accounts = accountsFor(player)
    for _, acc in ipairs(accounts) do acc.members = nil end
    return { accounts = accounts, citizenid = player.PlayerData.citizenid }
end)

Arca.Callback.Register('arca_bank:phoneTransfer', function(src, ref, target, amount, note)
    local player = getPlayer(src)
    if not player then return { ok = false } end
    local ok, msg = transfer(player, ref, target, amount, note)
    return { ok = ok, msg = msg }
end)

---------------------------------------------------------------------
-- Exports
---------------------------------------------------------------------
---Accounts a player can use (same shape the UI gets)
exports('GetAccounts', function(src) local p = getPlayer(src) return p and accountsFor(p) or {} end)
---Balance of any account ref ('p:CID', 'a:ID', 'job:police')
exports('GetBalance', balanceOf)
exports('AddMoney', function(ref, amount, reason) return change(ref, math.abs(money(amount)), reason or 'Deposit', 'System', 'deposit') end)
exports('RemoveMoney', function(ref, amount, reason) return change(ref, -math.abs(money(amount)), reason or 'Withdrawal', 'System', 'withdraw') end)
exports('Transfer', function(src, fromRef, target, amount, note) local p = getPlayer(src) if not p then return false end return transfer(p, fromRef, target, amount, note) end)
exports('HasAccess', function(src, ref) local p = getPlayer(src) return p ~= nil and accessOf(p, ref) ~= nil end)
exports('GetAccess', function(src, ref) local p = getPlayer(src) return p and accessOf(p, ref) end)
-- jobs
exports('GetJobAccount', function(job) return JobAccount[job] and ('a:' .. JobAccount[job]) or nil end)
exports('GetJobBalance', function(job) return JobAccount[job] and Accounts[JobAccount[job]].balance or 0 end)
exports('AddJobMoney', function(job, amount, reason) return change('job:' .. job, math.abs(money(amount)), reason or 'Deposit', 'System', 'deposit') end)
exports('RemoveJobMoney', function(job, amount, reason) return change('job:' .. job, -math.abs(money(amount)), reason or 'Withdrawal', 'System', 'withdraw') end)
---Create an extra account for a citizen from a script
exports('CreateAccount', function(citizenid, label, kind, ownerName)
    local id = MySQL.insert.await('INSERT INTO arca_bank_accounts (kind, label, owner, owner_name) VALUES (?, ?, ?, ?)', { kind or 'savings', label, citizenid, ownerName })
    Accounts[id] = { id = id, kind = kind or 'savings', label = label, owner = citizenid, ownerName = ownerName, balance = 0, members = {} }
    return 'a:' .. id
end)
exports('GetTransactions', function(ref, limit)
    ref = normRef(ref)
    if not ref then return {} end
    return MySQL.query.await('SELECT * FROM arca_bank_transactions WHERE ref = ? ORDER BY id DESC LIMIT ?', { ref, tonumber(limit) or 50 }) or {}
end)

---------------------------------------------------------------------
-- Startup / cleanup
---------------------------------------------------------------------
CreateThread(function()
    setupDatabase()
    loadAll()
    print(('^2[arca_bank]^7 %d accounts loaded'):format((function() local n = 0 for _ in pairs(Accounts) do n = n + 1 end return n end)()))
end)

-- log personal account changes made by other scripts too (paychecks, shops paying by bank...)
AddEventHandler('arca_core:server:onMoneyChange', function(src, mType, amount, reason)
    if mType ~= 'bank' or amount == 0 then return end
    if selfChange then return end -- already logged by change()
    local player = getPlayer(src)
    if not player then return end
    logTx('p:' .. player.PlayerData.citizenid, amount > 0 and 'deposit' or 'withdraw', amount, player.PlayerData.money.bank, reason or 'Bank', nil)
end)

AddEventHandler('playerDropped', function()
    atmUnlocked[source] = nil
end)
