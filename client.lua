-- Branches (teller peds + blips), ATMs and the bank / ATM screens.

local cfg = BankConfig
local isOpen = false
local tellers = {}

local function notify(msg, kind) exports.arca_core:Notify(msg, kind or 'inform') end

---------------------------------------------------------------------
-- Opening the screens
---------------------------------------------------------------------
-- a plain looped anim instead of the ATM scenario: scenarios play a long exit animation
-- (you're stuck until it ends), an anim can be stopped straight away with a short blend
local ATM_DICT, ATM_CLIP = 'amb@prop_human_atm@male@idle_a', 'idle_a'
local usingAtm = false

local function close()
    if not isOpen then return end
    isOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
    if usingAtm then
        usingAtm = false
        StopAnimTask(PlayerPedId(), ATM_DICT, ATM_CLIP, 3.0)
    end
end

local function canUse()
    if isOpen or not exports.arca_core:IsLoggedIn() then return false end
    if GetResourceState('arca_health') == 'started' and exports.arca_health:IsDown() then return false end
    if GetResourceState('arca_inventory') == 'started' and exports.arca_inventory:IsBusy() then return false end
    return true
end

local function openBank()
    if not canUse() then return end
    local data = Arca.Callback.Await('arca_bank:open')
    if not data then return notify('Talk to a teller at a bank branch', 'error') end
    isOpen = true
    SendNUIMessage({ action = 'bank', data = data })
    SetNuiFocus(true, true)
end

local function openAtm(entity)
    if not canUse() then return end
    local data = Arca.Callback.Await('arca_bank:atm')
    if not data then return end
    local ped = PlayerPedId()
    if entity then TaskTurnPedToFaceEntity(ped, entity, 600) Wait(600) end
    RequestAnimDict(ATM_DICT)
    local timeout = GetGameTimer() + 1500
    while not HasAnimDictLoaded(ATM_DICT) and GetGameTimer() < timeout do Wait(0) end
    TaskPlayAnim(ped, ATM_DICT, ATM_CLIP, 4.0, 3.0, -1, 1, 0, false, false, false)
    usingAtm = true
    isOpen = true
    SendNUIMessage({ action = 'atm', data = data })
    SetNuiFocus(true, true)
end

exports('OpenBank', openBank)
exports('OpenATM', openAtm)

---------------------------------------------------------------------
-- NUI → server (every reply is passed straight back to the page)
---------------------------------------------------------------------
RegisterNUICallback('close', function(_, cb) cb(1) close() end)

local passthrough = {
    transactions = function(d) return Arca.Callback.Await('arca_bank:transactions', d.ref) end,
    deposit = function(d) return Arca.Callback.Await('arca_bank:deposit', d.ref, d.amount) end,
    withdraw = function(d) return Arca.Callback.Await('arca_bank:withdraw', d.ref, d.amount) end,
    transfer = function(d) return Arca.Callback.Await('arca_bank:transfer', d.ref, d.target, d.amount, d.note) end,
    create = function(d) return Arca.Callback.Await('arca_bank:create', d.label, d.kind) end,
    rename = function(d) return Arca.Callback.Await('arca_bank:rename', d.ref, d.label) end,
    addMember = function(d) return Arca.Callback.Await('arca_bank:addMember', d.ref, d.citizenid) end,
    removeMember = function(d) return Arca.Callback.Await('arca_bank:removeMember', d.ref, d.citizenid) end,
    closeAccount = function(d) return Arca.Callback.Await('arca_bank:close', d.ref) end,
    setPin = function(d) return Arca.Callback.Await('arca_bank:setPin', d.ref, d.pin) end,
    atmUnlock = function(d) return Arca.Callback.Await('arca_bank:atmUnlock', d.ref, d.pin) end,
    atmWithdraw = function(d) return Arca.Callback.Await('arca_bank:atmWithdraw', d.ref, d.amount) end,
}
for name, fn in pairs(passthrough) do
    RegisterNUICallback(name, function(data, cb) cb(fn(data or {}) or false) end)
end

---------------------------------------------------------------------
-- Branches: blips + teller peds
---------------------------------------------------------------------
CreateThread(function()
    for _, b in ipairs(cfg.Branches) do
        local blip = AddBlipForCoord(b.ped.x, b.ped.y, b.ped.z)
        SetBlipSprite(blip, cfg.Blip.sprite)
        SetBlipColour(blip, cfg.Blip.color)
        SetBlipScale(blip, cfg.Blip.scale)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(b.label:match('^(.-) ·') or b.label)
        EndTextCommandSetBlipName(blip)
        -- hover card on the pause-menu map (arca_interface)
        if GetResourceState('arca_interface') == 'started' then
            exports.arca_interface:SetBlipInfo(blip, {
                title = b.label,
                description = 'Deposit, withdraw and manage your accounts and cards at the teller.',
                rows = { { 'Services', 'Accounts, cards' } },
            })
        end
    end
end)

local hasTarget = function() return GetResourceState('arca_target') == 'started' end

local function spawnTeller(b)
    local model = joaat(cfg.TellerModel)
    RequestModel(model)
    local timeout = GetGameTimer() + 5000
    while not HasModelLoaded(model) and GetGameTimer() < timeout do Wait(0) end
    if not HasModelLoaded(model) then return end
    local ped = CreatePed(4, model, b.ped.x, b.ped.y, b.ped.z - 1.0, b.ped.w, false, true)
    SetModelAsNoLongerNeeded(model)
    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetBlockingOfNonTemporaryEvents(ped, true)
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    if hasTarget() then
        -- pcall: arca_target may not be ready yet; the teller respawns when it starts
        pcall(function()
            exports.arca_target:addLocalEntity(ped, {
                { name = 'arca_bank:teller', label = 'Banking', icon = 'fa-solid fa-building-columns', distance = cfg.BranchRange, onSelect = openBank },
            })
        end)
    end
    return ped
end

CreateThread(function()
    local prompt
    while true do
        local coords = GetEntityCoords(PlayerPedId())
        local near
        for i, b in ipairs(cfg.Branches) do
            local dist = #(coords - vector3(b.ped.x, b.ped.y, b.ped.z))
            if dist < 40.0 and not tellers[i] then
                tellers[i] = spawnTeller(b)
            elseif dist > 50.0 and tellers[i] then
                DeleteEntity(tellers[i])
                tellers[i] = nil
            end
            if dist < 2.2 then near = b end
        end
        -- without arca_target: walk up and press E
        if near and not hasTarget() and not isOpen then
            if prompt ~= near then
                exports.arca_core:ShowTextUI('[E] Banking', { icon = 'fa-solid fa-building-columns' })
                prompt = near
            end
            if IsControlJustPressed(0, 38) then openBank() end
            Wait(0)
        else
            if prompt then exports.arca_core:HideTextUI() prompt = nil end
            Wait(500)
        end
    end
end)

---------------------------------------------------------------------
-- ATMs
---------------------------------------------------------------------
local function registerTargets()
    exports.arca_target:addModel(cfg.AtmModels, {
        { name = 'arca_bank:atm', label = 'Use ATM', icon = 'fa-solid fa-credit-card', distance = 0.7,
          onSelect = function(data) openAtm(data.entity) end },
    })
end

-- arca_target can report 'started' before its exports exist: keep trying
CreateThread(function()
    for _ = 1, 60 do
        if hasTarget() and pcall(registerTargets) then break end
        Wait(500)
    end
end)
AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= 'arca_target' then return end
    registerTargets()
    for i, ped in pairs(tellers) do DeleteEntity(ped) tellers[i] = nil end
end)

-- Many ATMs (e.g. the ones built into Fleeca walls) sit inside wall collision, so the third-eye
-- ray hits the wall instead of the ATM. Give every ATM near the player a small zone as well.
CreateThread(function()
    local hashes = {}
    for _, m in ipairs(cfg.AtmModels) do hashes[joaat(m)] = true end
    local zones = {} -- ["x:y:z"] = zone id
    while true do
        if hasTarget() and LocalPlayer.state.isLoggedIn then
            local me = GetEntityCoords(PlayerPedId())
            local found = {}
            local function consider(obj)
                if obj == 0 or not hashes[GetEntityModel(obj)] then return end
                local c = GetEntityCoords(obj)
                if #(me - c) > 40.0 then return end
                local key = ('%d:%d:%d'):format(math.floor(c.x), math.floor(c.y), math.floor(c.z))
                found[key] = true
                if not zones[key] then
                    local ok, id = pcall(function()
                        return exports.arca_target:addSphereZone({
                            coords = GetOffsetFromEntityInWorldCoords(obj, 0.0, -0.1, 1.0),
                            radius = 0.9,
                            options = {
                                { name = 'arca_bank:atm', label = 'Use ATM', icon = 'fa-solid fa-credit-card', distance = 1.6,
                                  onSelect = function() openAtm(obj) end },
                            },
                        })
                    end)
                    if ok then zones[key] = id end
                end
            end
            for _, obj in ipairs(GetGamePool('CObject')) do consider(obj) end
            for hash in pairs(hashes) do consider(GetClosestObjectOfType(me.x, me.y, me.z, 40.0, hash, false, false, false)) end
            -- drop zones for ATMs we walked away from
            for key, id in pairs(zones) do
                if not found[key] then
                    pcall(function() exports.arca_target:removeZone(id) end)
                    zones[key] = nil
                end
            end
        end
        Wait(1500)
    end
end)

-- without arca_target: [E] at an ATM
CreateThread(function()
    local hashes = {}
    for _, m in ipairs(cfg.AtmModels) do hashes[#hashes + 1] = joaat(m) end
    local shown = false
    while true do
        local sleep = 1000
        if not hasTarget() and not isOpen and LocalPlayer.state.isLoggedIn then
            local c = GetEntityCoords(PlayerPedId())
            local atm
            for _, h in ipairs(hashes) do
                local obj = GetClosestObjectOfType(c.x, c.y, c.z, 1.2, h, false, false, false)
                if obj ~= 0 then atm = obj break end
            end
            if atm then
                sleep = 0
                if not shown then exports.arca_core:ShowTextUI('[E] Use ATM', { icon = 'fa-solid fa-credit-card' }) shown = true end
                if IsControlJustPressed(0, 38) then openAtm(atm) end
            elseif shown then
                exports.arca_core:HideTextUI()
                shown = false
            end
        elseif shown then
            exports.arca_core:HideTextUI()
            shown = false
        end
        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for _, ped in pairs(tellers) do DeleteEntity(ped) end
    if isOpen then SetNuiFocus(false, false) end
end)
