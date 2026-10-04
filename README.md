# arca_bank

Banking for the Arca framework: personal, savings, shared and job accounts, Fleeca branches with tellers, ATMs with card PINs, and a Fleeca app on the phone.

## Accounts

| Type | Who can use it | Notes |
|---|---|---|
| **Personal** | the character | Everyone has one. It is the arca_core `bank` balance, so `player.AddMoney('bank', ...)` keeps working. It can't be shared or closed. |
| **Savings / Shared / Business** | the owner, plus anyone they add | Opened at a branch (up to `MaxAccountsPerPlayer`). The owner renames it, adds or removes people by citizen ID, and closes it. When it closes, the balance goes to the owner's personal account. |
| **Job** | job members at or above `minGrade` | Created automatically for every job with `bank = { minGrade = n }` in `arca_core/shared/jobs.lua`. |

## Where you can do what

| | Branch (teller) | ATM | Phone (Fleeca app) |
|---|---|---|---|
| View balances and activity | ✓ | balance | ✓ |
| Deposit cash | ✓ | | |
| Withdraw cash | ✓ | ✓ (with PIN) | |
| Transfer | ✓ | | ✓ |
| Open, rename or close accounts, manage access | ✓ | | |
| Set a card PIN | ✓ | | |

**Cards:** setting a PIN on an account turns it into a "virtual card". ATMs only list accounts you can use, and only accounts with a card can be used there. Three wrong PINs lock the card for 2 minutes.

**Transfers:** a transfer goes to a **citizen ID** (that person's personal account, even if they're offline) or an **account number**.

## Locations

- Every Fleeca branch, Blaine County Savings (Paleto) and Pacific Standard, each with a teller ped and a map blip. Third-eye the teller, or walk up and press **E**.
- ATMs: every `prop_atm_01/02/03` and `prop_fleeca_atm` in the map. Third-eye one, or press **E** next to it.

## Exports (server)

Account refs: `'p:<citizenid>'` (personal), `'a:<id>'` (extra or job account), `'job:<name>'` (shortcut for a job account).

```lua
local bank = exports.arca_bank

bank:GetAccounts(source)                       -- accounts the player can use
bank:GetBalance('job:police')                  -- any ref
bank:AddMoney('a:1004', 500, 'Rent')           -- true / false
bank:RemoveMoney('p:ABC12345', 200, 'Fine')    -- false if there isn't enough
bank:Transfer(source, 'p:ABC12345', '1004', 250, 'note')
bank:HasAccess(source, ref)  /  bank:GetAccess(source, ref)  -- 'personal' | 'manage' | 'use' | nil
bank:GetJobAccount('police')                   -- 'a:1001'
bank:GetJobBalance('police')
bank:AddJobMoney('police', 1000, 'City budget')
bank:RemoveJobMoney('police', 300, 'Equipment')
bank:CreateAccount(citizenid, 'Business', 'business', ownerName)  -- returns the new ref
bank:GetTransactions(ref, 50)
```

## Exports (client)

`OpenBank()`, `OpenATM(entity?)`
