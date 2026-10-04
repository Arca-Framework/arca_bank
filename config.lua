BankConfig = {
    -- Extra accounts a player can open (their personal account doesn't count)
    MaxAccountsPerPlayer = 3,
    AccountTypes = {
        { id = 'savings', label = 'Savings', icon = 'fa-solid fa-piggy-bank' },
        { id = 'shared', label = 'Shared', icon = 'fa-solid fa-people-group' },
        { id = 'business', label = 'Business', icon = 'fa-solid fa-briefcase' },
    },
    MaxMembers = 8,             -- people (besides the owner) on one account

    -- Cards / ATMs: a 4-digit PIN turns an account into a card that works at ATMs
    PinLength = 4,
    PinAttempts = 3,            -- wrong PINs before the card is locked
    PinLockTime = 120,          -- seconds locked
    AtmMaxWithdraw = 5000,      -- per transaction
    AtmQuickAmounts = { 50, 100, 200, 500, 1000 },

    -- Fleeca branches (and the two big banks). ped = teller position.
    Branches = {
        { label = 'Fleeca · Legion Square',   ped = vector4(149.42, -1042.17, 29.37, 340.0) },
        { label = 'Fleeca · Hawick Ave',      ped = vector4(313.79, -280.48, 54.16, 340.0) },
        { label = 'Fleeca · Burton',          ped = vector4(-351.29, -51.27, 49.04, 340.0) },
        { label = 'Fleeca · Rockford Hills',  ped = vector4(-1211.99, -331.95, 37.78, 25.0) },
        { label = 'Fleeca · Great Ocean Hwy', ped = vector4(-2961.13, 482.97, 15.70, 85.0) },
        { label = 'Fleeca · Route 68',        ped = vector4(1174.98, 2708.18, 38.09, 180.0) },
        { label = 'Blaine County Savings',    ped = vector4(-111.17, 6469.98, 31.63, 135.0) },
        { label = 'Pacific Standard',         ped = vector4(247.06, 225.31, 106.29, 160.0) },
    },
    TellerModel = 'ig_bankman',
    BranchRange = 2.0,          -- how close to the teller the bank UI works
    Blip = { sprite = 108, color = 2, scale = 0.7 },

    AtmModels = { 'prop_atm_01', 'prop_atm_02', 'prop_atm_03', 'prop_fleeca_atm' },
}
