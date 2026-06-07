// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/**
 * @title  StepNetLib
 * @notice Aggregated companion file for the StepNet contract. Contains:
 *           1) The file-level `User` struct used by storage in StepNet,
 *              shared with `WalletLib` so wallet-migration logic can
 *              operate on storage references without redeclaring types.
 *           2) The file-level `ImportUserData` struct used during initial
 *              state import.
 *           3) `ReserveLib`  — external library encapsulating per-subscriber
 *              reserve-ticket bookkeeping (compaction + consumption).
 *           4) `WalletLib`   — external library encapsulating wallet
 *              migration (`changeWallet`). Invoked via DELEGATECALL.
 *           5) `PendingLib`  — external library encapsulating referral
 *              graph propagation, deferred-update processing, and the
 *              permanent Box-0 subtree counters used for DAO voting.
 *           6) `StepNetImporter` — one-shot batch-import helper used to
 *              seed user state during migration. Deployed separately.
 *         Co-locating these units in a single file simplifies versioning
 *         while keeping deployed bytecode boundaries unchanged.
 */

// ═══════════════════════════════════════════════════════════════════════════
//  File-level types
// ═══════════════════════════════════════════════════════════════════════════

/// @notice Per-subscriber state record. Declared at file scope so that
///         `WalletLib` can operate on storage references to mappings of
///         this type without redeclaration. Field order is the canonical
///         storage layout of StepNet and must not be reordered.
struct User {
    uint256[6] boxPurchasedCount;
    uint256[6] totalPaidPerBox;
    uint256    totalPaidAllBoxes;
    address    upline;
    address    left;
    address    right;
    uint256[6] teamLeftCount;
    uint256[6] teamRightCount;
    uint256    totalCommissionDai;
    uint256    reservedForUpgrade;
    uint256    stepReceivedFromClub;
    uint256    amountBurnedStepClub;
    uint256    totalBurnedByUser;
    bool       inStepClub;
    uint256    startTimestamp;
    uint256    reserveCycleStart;
    uint256    clubJoinedTimestamp;
    uint256    stepBurnedFromClub;
    uint256    stepEquivFromBoxes;
}

/// @notice Payload type for `StepNet.importSingleUser` /
///         `StepNetImporter.batchImport`. Encodes every observable piece of
///         per-subscriber state so an off-chain export pipeline can
///         re-seed a fresh deployment.
struct ImportUserData {
    address ua;
    address upline;
    address left;
    address right;
    uint256[6] boxPurchasedCount;
    uint256[6] totalPaidPerBox;
    uint256 totalPaidAllBoxes;
    uint256[6] teamLeftCount;
    uint256[6] teamRightCount;
    uint256 totalCommissionDai;
    uint256 reservedForUpgrade;
    uint256 stepReceivedFromClub;
    uint256 amountBurnedStepClub;
    uint256 totalBurnedByUser;
    bool    inStepClub;
    string  name;
    uint256 startTimestamp;
    uint256 reserveCycleStart;
    uint256 clubJoinedTimestamp;
    uint256[6] pendingDaiRewards;
    uint256 pendingClubReward;
    uint256 clubJoinedAfterDistCount;
}

// ═══════════════════════════════════════════════════════════════════════════
//  ReserveLib — deployed as a standalone external library; callers invoke
//  via DELEGATECALL so all storage updates land on the calling contract.
//  Keeps StepNet bytecode under the EIP-170 cap.
// ═══════════════════════════════════════════════════════════════════════════

library ReserveLib {
    struct ReserveTicket {
        uint256 amount;
        uint256 addedAt;
    }

    /// @dev Must match `MAX_RESERVE_BATCH` in StepNet.
    uint256 internal constant MAX_BATCH = 100;
    /// @dev Must match `RESERVE_BURN_INTERVAL` in StepNet.
    uint256 internal constant RESERVE_BURN_INTERVAL = 90 days;

    /// @notice Bounded compaction of a subscriber's reserve-ticket queue.
    ///         Shifts active entries to the front when feasible and pops
    ///         the consumed prefix; throttled to MAX_BATCH operations.
    function compact(
        mapping(address => ReserveTicket[]) storage reserveTickets,
        mapping(address => uint256)         storage reserveTicketHead,
        address ua
    ) external {
        _compact(reserveTickets, reserveTicketHead, ua);
    }

    function _compact(
        mapping(address => ReserveTicket[]) storage reserveTickets,
        mapping(address => uint256)         storage reserveTicketHead,
        address ua
    ) private {
        uint256 head = reserveTicketHead[ua];
        if (head == 0) return;
        ReserveTicket[] storage tickets = reserveTickets[ua];
        uint256 len = tickets.length;

        if (head >= len) {
            uint256 toPop = len > MAX_BATCH ? MAX_BATCH : len;
            for (uint256 i = 0; i < toPop;) {
                tickets.pop();
                unchecked { ++i; }
            }
            reserveTicketHead[ua] = len - toPop;
            return;
        }

        uint256 newLen = len - head;
        if (newLen > MAX_BATCH) {
            return;
        }
        for (uint256 i = 0; i < newLen;) {
            tickets[i] = tickets[head + i];
            unchecked { ++i; }
        }
        for (uint256 i = newLen; i < len;) {
            tickets.pop();
            unchecked { ++i; }
        }
        reserveTicketHead[ua] = 0;
    }

    /// @notice Accounting half of StepNet's expired-reserve burn. Advances the
    ///         ticket head past expired tickets (or, when the queue is empty,
    ///         honours the `reserveCycleStart` fallback), debits the
    ///         subscriber's reserve + burn counters, and returns the DAI amount
    ///         the caller must donate to liquidity. The DEX/donate/emit half is
    ///         kept in StepNet; this library handles the accounting half only.
    function burnExpired(
        mapping(address => ReserveTicket[]) storage reserveTickets,
        mapping(address => uint256)         storage reserveTicketHead,
        User storage u,
        address ua
    ) external returns (uint256 toBurn) {
        if (u.reservedForUpgrade == 0) return 0;
        ReserveTicket[] storage tickets = reserveTickets[ua];
        uint256 head = reserveTicketHead[ua];
        uint256 len  = tickets.length;

        if (head >= len) {
            if (u.reserveCycleStart == 0) return 0;
            if (block.timestamp < u.reserveCycleStart + RESERVE_BURN_INTERVAL) return 0;
            toBurn = u.reservedForUpgrade;
            u.reservedForUpgrade = 0;
            u.reserveCycleStart = 0;
            u.amountBurnedStepClub += toBurn;
            u.totalBurnedByUser += toBurn;
            return toBurn;
        }

        if (block.timestamp < tickets[head].addedAt + RESERVE_BURN_INTERVAL) return 0;

        uint256 newHead = head;
        uint256 batchEnd = newHead + MAX_BATCH;
        if (batchEnd > len) batchEnd = len;
        while (newHead < batchEnd) {
            if (block.timestamp < tickets[newHead].addedAt + RESERVE_BURN_INTERVAL) break;
            toBurn += tickets[newHead].amount;
            unchecked { ++newHead; }
        }
        if (toBurn == 0) return 0;

        reserveTicketHead[ua] = newHead;
        u.reservedForUpgrade -= toBurn;
        u.amountBurnedStepClub += toBurn;
        u.totalBurnedByUser += toBurn;

        // Amortised compaction once the ticket queue is fully drained.
        if (newHead >= len) _compact(reserveTickets, reserveTicketHead, ua);
    }

    /// @notice Spend `amountToConsume` DAI from the head of the
    ///         subscriber's reserve-ticket queue (FIFO).
    function consume(
        mapping(address => ReserveTicket[]) storage reserveTickets,
        mapping(address => uint256)         storage reserveTicketHead,
        address ua,
        uint256 amountToConsume
    ) external {
        ReserveTicket[] storage tickets = reserveTickets[ua];
        uint256 head = reserveTicketHead[ua];
        uint256 len = tickets.length;
        uint256 remaining = amountToConsume;

        while (remaining > 0 && head < len) {
            uint256 ticketAmt = tickets[head].amount;
            if (ticketAmt <= remaining) {
                remaining -= ticketAmt;
                unchecked { ++head; }
            } else {
                tickets[head].amount = ticketAmt - remaining;
                remaining = 0;
            }
        }
        reserveTicketHead[ua] = head;
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  WalletLib — encapsulates the multi-step wallet-migration routine. Runs
//  via DELEGATECALL so storage operations land on StepNet. `msg.sender`
//  and the Club address are passed explicitly so the routine is purely a
//  function of its arguments (easier to audit, easier to unit-test).
// ═══════════════════════════════════════════════════════════════════════════

interface IClubTransfer {
    function transferMembership(address oldAddr, address newAddr) external;
}

library WalletLib {
    uint256 internal constant BOX_COUNT = 6;

    // Mirror StepNet's custom error selectors so reverts surface identically.
    error ZeroAddress();
    error SameWallet();
    error NewWalletUsed();
    error MaxChanges();
    error NotRegistered();

    event WalletChanged(address indexed oldWallet, address indexed newWallet);

    /// @notice Migrate every piece of per-subscriber state from `sender`
    ///         to `newWallet`. Runs the full 14-step routine atomically
    ///         under StepNet's storage.
    /// @param sender The original `msg.sender` of `StepNet.changeWallet`.
    /// @param club   The current Club treasury address (resolved by StepNet
    ///               and forwarded so this library does not depend on the
    ///               registry directly).
    function changeWallet(
        // storage references — in order of use in the body
        mapping(address => User)                            storage users,
        mapping(address => uint256)                         storage walletChangeCount,
        mapping(address => address)                         storage oldToNewWallet,
        mapping(address => address)                         storage newToOldWallet,
        mapping(address => mapping(uint256 => uint256))     storage pendingBoxDaiRewards,
        mapping(address => mapping(uint256 => uint256))     storage boxActivatedAt,
        mapping(address => ReserveLib.ReserveTicket[])      storage reserveTickets,
        mapping(address => uint256)                         storage reserveTicketHead,
        mapping(address => mapping(uint256 => uint256))     storage lastDailyBurnedPointsUser,
        mapping(address => mapping(uint256 => address))     storage lastUpdatedUpline,
        mapping(address => mapping(uint256 => address))     storage lastUpdatedChild,
        mapping(uint256 => mapping(address => uint256))     storage pendingUpdateIndex,
        mapping(uint256 => address[])                       storage pendingUpdates,
        mapping(address => bool)                            storage hasPendingUpgrade,
        mapping(address => uint256)                         storage pendingUpgradeIndex,
        address[]                                           storage pendingUpgradeList,
        mapping(address => bool)                            storage processed,
        mapping(address => uint256)                         storage activeUsersIndex,
        address[]                                           storage activeUsers,
        mapping(address => string)                          storage userName,
        address                                             sender,
        address                                             newWallet,
        address                                             club
    ) external {
        // Pre-checks
        if (newWallet == address(0))                       revert ZeroAddress();
        if (newWallet == sender)                           revert SameWallet();
        if (users[newWallet].totalPaidAllBoxes != 0)       revert NewWalletUsed();
        if (oldToNewWallet[newWallet] != address(0))       revert NewWalletUsed();
        if (walletChangeCount[sender] >= 3)                revert MaxChanges();
        if (users[sender].totalPaidAllBoxes == 0)          revert NotRegistered();

        // 1. Full struct copy.
        users[newWallet] = users[sender];

        // 2. Re-point the upline's child slot.
        address upline = users[sender].upline;
        if (upline != address(0)) {
            if (users[upline].left  == sender) users[upline].left  = newWallet;
            if (users[upline].right == sender) users[upline].right = newWallet;
        }

        // 3. Re-point the downline children.
        address leftChild  = users[sender].left;
        address rightChild = users[sender].right;
        if (leftChild  != address(0)) users[leftChild ].upline = newWallet;
        if (rightChild != address(0)) users[rightChild].upline = newWallet;

        // 4. Move pending DAI rewards.
        for (uint256 i = 0; i < BOX_COUNT; i++) {
            pendingBoxDaiRewards[newWallet][i] = pendingBoxDaiRewards[sender][i];
            delete pendingBoxDaiRewards[sender][i];
        }

        // 5. Move activation timestamps.
        for (uint256 i = 0; i < BOX_COUNT; i++) {
            boxActivatedAt[newWallet][i] = boxActivatedAt[sender][i];
            delete boxActivatedAt[sender][i];
        }

        // 6. Forward Club membership.
        if (users[sender].inStepClub) IClubTransfer(club).transferMembership(sender, newWallet);

        // 7. Migrate reserve tickets (compact, then copy, then clear old).
        ReserveLib.compact(reserveTickets, reserveTicketHead, sender);
        {
            ReserveLib.ReserveTicket[] storage oldT = reserveTickets[sender];
            uint256 len = oldT.length;
            for (uint256 t = 0; t < len;) {
                reserveTickets[newWallet].push(oldT[t]);
                unchecked { ++t; }
            }
            reserveTicketHead[newWallet] = 0;
            for (uint256 t = 0; t < len;) {
                oldT.pop();
                unchecked { ++t; }
            }
            reserveTicketHead[sender] = 0;
        }

        // 8. Move the daily-burn point ledger.
        for (uint256 i = 0; i < BOX_COUNT; i++) {
            lastDailyBurnedPointsUser[newWallet][i] = lastDailyBurnedPointsUser[sender][i];
            delete lastDailyBurnedPointsUser[sender][i];
        }

        // 9. O(1) rebinding of the pendingUpdates queue entries.
        for (uint256 b = 0; b < BOX_COUNT; b++) {
            address su = lastUpdatedUpline[sender][b];
            if (su != address(0)) {
                lastUpdatedUpline[newWallet][b] = su;
                lastUpdatedChild[newWallet][b]  = lastUpdatedChild[sender][b];
                delete lastUpdatedUpline[sender][b];
                delete lastUpdatedChild[sender][b];
                uint256 pIdx = pendingUpdateIndex[b][sender];
                if (pIdx != 0) {
                    pendingUpdates[b][pIdx - 1]      = newWallet;
                    pendingUpdateIndex[b][newWallet] = pIdx;
                    pendingUpdateIndex[b][sender]    = 0;
                }
            }
        }

        // 10. O(1) rebinding of the pendingUpgrade queue.
        if (hasPendingUpgrade[sender]) {
            hasPendingUpgrade[newWallet] = true;
            hasPendingUpgrade[sender] = false;
            uint256 upIdx = pendingUpgradeIndex[sender];
            if (upIdx != 0) {
                pendingUpgradeList[upIdx - 1]  = newWallet;
                pendingUpgradeIndex[newWallet] = upIdx;
                pendingUpgradeIndex[sender]    = 0;
            }
        }

        // 11. O(1) rebinding of the activeUsers array.
        if (processed[sender]) {
            uint256 idx = activeUsersIndex[sender];
            if (idx != 0) {
                activeUsers[idx - 1]        = newWallet;
                activeUsersIndex[newWallet] = idx;
                activeUsersIndex[sender]    = 0;
            }
            processed[newWallet] = true;
            processed[sender]    = false;
        }

        // 12. Cross-mapping pointers + bump the migration counter.
        oldToNewWallet[sender]       = newWallet;
        newToOldWallet[newWallet]    = sender;
        walletChangeCount[newWallet] = walletChangeCount[sender] + 1;

        // 13. Move the display name.
        userName[newWallet] = userName[sender];
        delete userName[sender];

        // 14. Retire the old record.
        delete users[sender];

        emit WalletChanged(sender, newWallet);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  PendingLib — referral-graph propagation utilities. Exposes:
//    • propagate              — eager up-tree walk (up to IMMEDIATE_UPDATE_LEVELS);
//                               also advances the permanent Box-0 voting counters
//                               for Box-0 activations (never decremented)
//    • processBatch           — bounded continuation of deferred propagation,
//                               carrying the Box-0 counters to the root in lock-step
//    • _removeAt              — internal queue maintenance (private)
//    • rebuildBox0SubtreeBatch — one-shot Box-0 counter backfill for imports
//  Invoked via DELEGATECALL so storage and events live under the caller.
// ═══════════════════════════════════════════════════════════════════════════

library PendingLib {
    uint256 internal constant IMMEDIATE_UPDATE_LEVELS = 70;

    /// @notice Walk up to IMMEDIATE_UPDATE_LEVELS upline levels and credit
    ///         the newly-activated subscriber to each upline's left/right
    ///         team counter. If the walk reaches the level cap before the
    ///         tree root, the remaining propagation is enqueued for later
    ///         draining by `processBatch`.
    /// @dev O(1) dedup-insert of a touched upline into the per-box dirty set.
    ///      Stored as `index + 1`; a zero value means "absent". This is the
    ///      mechanism that lets the daily distribution iterate ONLY the
    ///      uplines whose team counters actually changed this round, rather
    ///      than the entire subscriber set. The result is exact: an untouched
    ///      upline has a zero weaker-leg and therefore contributes nothing to
    ///      the distribution.
    function _markDirty(
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        uint256 boxId,
        address ua
    ) private {
        if (dirtyIndex[boxId][ua] == 0) {
            dirtyUsers[boxId].push(ua);
            dirtyIndex[boxId][ua] = dirtyUsers[boxId].length; // idx+1
        }
    }

    // ─── External dirty/reserve-set helpers (DELEGATECALL from StepNet) ──────
    //  These live here purely to keep StepNet's deployed bytecode under the
    //  EIP-170 cap; storage updates land on the calling contract.

    /// @notice External dedup-insert used by StepNet's import seeding.
    function markDirty(
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        uint256 boxId,
        address ua
    ) external {
        _markDirty(dirtyUsers, dirtyIndex, boxId, ua);
    }

    /// @notice Removes the processed window `[0, processedEnd)` from a tier's
    ///         dirty set after its cycle finalizes; entries pushed mid-cycle
    ///         survive and shift to the front. Per-entry `dirtyIndex` of the
    ///         processed window was already zeroed during the phase-0 pass.
    function clearDirtyBox(
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        uint256 boxId,
        uint256 processedEnd
    ) external {
        address[] storage arr = dirtyUsers[boxId];
        uint256 len = arr.length;
        if (processedEnd >= len) {
            delete dirtyUsers[boxId];
            return;
        }
        uint256 newLen = len - processedEnd;
        for (uint256 i = 0; i < newLen; ) {
            address a = arr[processedEnd + i];
            arr[i] = a;
            dirtyIndex[boxId][a] = i + 1;
            unchecked { ++i; }
        }
        for (uint256 i = 0; i < processedEnd; ) {
            arr.pop();
            unchecked { ++i; }
        }
    }

    /// @notice O(1) dedup-insert into the active-reserve set.
    function addReserveUser(
        address[]                   storage reserveUsers,
        mapping(address => uint256) storage reserveUserIndex,
        address ua
    ) external {
        if (reserveUserIndex[ua] == 0) {
            reserveUsers.push(ua);
            reserveUserIndex[ua] = reserveUsers.length; // idx+1
        }
    }

    /// @notice O(1) swap-pop removal from the active-reserve set.
    function removeReserveUserAt(
        address[]                   storage reserveUsers,
        mapping(address => uint256) storage reserveUserIndex,
        uint256 i,
        address ua
    ) external {
        uint256 last = reserveUsers.length - 1;
        if (i != last) {
            address moved = reserveUsers[last];
            reserveUsers[i] = moved;
            reserveUserIndex[moved] = i + 1;
        }
        reserveUsers.pop();
        reserveUserIndex[ua] = 0;
    }

    function _boxPriceLib(uint8 id) private pure returns (uint256) {
        if (id == 1) return 75 ether;
        if (id == 2) return 100 ether;
        if (id == 3) return 300 ether;
        if (id == 4) return 500 ether;
        return 1000 ether; // id == 5 (id 0 never queried here)
    }

    /// @dev Must match `DAILY_CAP` in StepNet.
    uint256 internal constant DAILY_CAP = 15;
    /// @dev Declared with the same signature as StepNet's event so that, when
    ///      emitted via DELEGATECALL, the log topic hash matches exactly
    ///      (same signature ⇒ same selector ⇒ same log).
    event DailyPointsBurned(address indexed user, uint256 indexed boxId, uint256 burnedPoints);

    /// @notice Phase-0 of the daily distribution for one tier: tallies capped
    ///         weaker-leg points for owners and burns the team counters of
    ///         non-owners, over the tier's dirty window only. Runs in this
    ///         library (DELEGATECALL) to keep StepNet under the EIP-170 cap.
    ///         Returns true when the window is fully processed, false when it
    ///         yielded on the gas checkpoint.
    function distPhase0(
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(address => User)                        storage users,
        mapping(uint256 => uint256)                     storage dailyTotalPoints,
        mapping(uint256 => uint256)                     storage dailyCursor,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        mapping(uint256 => uint256)                     storage lastRoundBurnedPointsPerBox,
        uint256 boxId,
        uint256 totalUsers
    ) external returns (bool) {
        while (dailyCursor[boxId] < totalUsers) {
            uint256 remaining = totalUsers - dailyCursor[boxId];
            // Workload-scaled gas floor before yielding mid-window.
            uint256 safetyGas = 55_000 + (remaining > 50 ? 50 : remaining) * 2_000;
            if (gasleft() < safetyGas && remaining > 10) return false;

            address ua = dirtyUsers[boxId][dailyCursor[boxId]];
            User storage u = users[ua];

            if (u.boxPurchasedCount[boxId] > 0) {
                uint256 a = u.teamLeftCount[boxId];
                uint256 b = u.teamRightCount[boxId];
                uint256 w = a < b ? a : b;
                dailyTotalPoints[boxId] += (w > DAILY_CAP ? DAILY_CAP : w);
            } else {
                uint256 burnedL = u.teamLeftCount[boxId];
                uint256 burnedR = u.teamRightCount[boxId];
                if (burnedL > 0 || burnedR > 0) {
                    u.teamLeftCount[boxId] = 0;
                    u.teamRightCount[boxId] = 0;
                    lastRoundBurnedPointsPerBox[boxId] += (burnedL + burnedR);
                    emit DailyPointsBurned(ua, boxId, burnedL + burnedR);
                }
            }
            dirtyIndex[boxId][ua] = 0;
            unchecked { dailyCursor[boxId]++; }
        }
        return true;
    }

    /// @notice Queue `ua` for auto-upgrade when its reserve covers the next
    ///         tier price. Runs in this library (DELEGATECALL) for size.
    function markPendingUpgrade(
        mapping(address => User)    storage users,
        mapping(address => bool)    storage hasPendingUpgrade,
        address[]                   storage pendingUpgradeList,
        mapping(address => uint256) storage pendingUpgradeIndex,
        address ua
    ) external {
        if (hasPendingUpgrade[ua]) return;
        User storage u = users[ua];
        for (uint256 i = 0; i < 5;) {
            if (u.boxPurchasedCount[i] > 0 && u.boxPurchasedCount[i+1] == 0) {
                if (u.reservedForUpgrade >= _boxPriceLib(uint8(i+1))) {
                    hasPendingUpgrade[ua] = true;
                    pendingUpgradeList.push(ua);
                    pendingUpgradeIndex[ua] = pendingUpgradeList.length; // idx+1
                }
                break;
            }
            unchecked { ++i; }
        }
    }

    function propagate(
        mapping(address => User)                        storage users,
        mapping(uint256 => address[])                   storage pendingUpdates,
        mapping(uint256 => mapping(address => uint256)) storage pendingUpdateIndex,
        mapping(address => mapping(uint256 => address)) storage lastUpdatedUpline,
        mapping(address => mapping(uint256 => address)) storage lastUpdatedChild,
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        mapping(address => uint256)                     storage box0LeftSubtree,
        mapping(address => uint256)                     storage box0RightSubtree,
        address target,
        address child,
        uint256 boxId
    ) external {
        address current = users[child].upline;
        if (current == address(0)) return;
        // Box-0 activations additionally feed the permanent voting counters,
        // which ride along the exact same up-tree walk (immediate window here,
        // remainder drained by `processBatch`) so they reach the root too.
        bool isBox0 = (boxId == 0);
        uint256 levels = 0;
        bool isLeft = (users[current].left == child);
        while (current != address(0) && levels < IMMEDIATE_UPDATE_LEVELS) {
            if (isLeft) {
                users[current].teamLeftCount[boxId]++;
                if (isBox0) box0LeftSubtree[current]++;
            } else {
                users[current].teamRightCount[boxId]++;
                if (isBox0) box0RightSubtree[current]++;
            }
            _markDirty(dirtyUsers, dirtyIndex, boxId, current);
            levels++;
            child = current;
            current = users[current].upline;
            if (current != address(0)) isLeft = (users[current].left == child);
        }
        if (current != address(0)) {
            pendingUpdates[boxId].push(target);
            pendingUpdateIndex[boxId][target] = pendingUpdates[boxId].length; // idx+1
            lastUpdatedUpline[target][boxId] = current;
            lastUpdatedChild[target][boxId] = child;
        }
    }

    /// @notice Drain up to `maxUsers` deferred propagation jobs from the
    ///         pendingUpdates queue for the given tier. Each entry is
    ///         advanced by up to 15 additional levels per call so very deep
    ///         trees converge across multiple keeper transactions.
    function processBatch(
        mapping(address => User)                        storage users,
        mapping(uint256 => address[])                   storage pendingUpdates,
        mapping(uint256 => mapping(address => uint256)) storage pendingUpdateIndex,
        mapping(address => mapping(uint256 => address)) storage lastUpdatedUpline,
        mapping(address => mapping(uint256 => address)) storage lastUpdatedChild,
        mapping(uint256 => address[])                   storage dirtyUsers,
        mapping(uint256 => mapping(address => uint256)) storage dirtyIndex,
        mapping(address => uint256)                     storage box0LeftSubtree,
        mapping(address => uint256)                     storage box0RightSubtree,
        uint256 boxId,
        uint256 maxUsers
    ) external {
        uint256 length = pendingUpdates[boxId].length;
        if (length == 0) return;
        // Continuation of the same walk started in `propagate`; for Box-0 the
        // permanent voting counters are advanced in lock-step so they converge
        // to the root across keeper calls, exactly like the team counts.
        bool isBox0 = (boxId == 0);
        uint256 cnt = 0;
        for (uint256 i = 0; i < length && cnt < maxUsers;) {
            address target = pendingUpdates[boxId][i];
            address current = lastUpdatedUpline[target][boxId];
            if (current == address(0)) {
                _removeAt(pendingUpdates, pendingUpdateIndex, boxId, i);
                length--;
                continue;
            }
            address child = lastUpdatedChild[target][boxId];
            bool isLeft = (users[current].left == child);
            uint256 sub = 0;
            while (current != address(0) && sub < 15) {
                if (isLeft) {
                    users[current].teamLeftCount[boxId]++;
                    if (isBox0) box0LeftSubtree[current]++;
                } else {
                    users[current].teamRightCount[boxId]++;
                    if (isBox0) box0RightSubtree[current]++;
                }
                _markDirty(dirtyUsers, dirtyIndex, boxId, current);
                sub++;
                child = current;
                current = users[current].upline;
                if (current != address(0)) isLeft = (users[current].left == child);
            }
            if (current == address(0)) {
                _removeAt(pendingUpdates, pendingUpdateIndex, boxId, i);
                length--;
                delete lastUpdatedUpline[target][boxId];
                delete lastUpdatedChild[target][boxId];
            } else {
                lastUpdatedUpline[target][boxId] = current;
                lastUpdatedChild[target][boxId] = child;
                unchecked { ++i; }
            }
            unchecked { ++cnt; }
        }
    }

    /// @dev O(1) swap-and-pop removal from the pendingUpdates queue,
    ///      keeping the reverse index consistent.
    function _removeAt(
        mapping(uint256 => address[])                   storage pendingUpdates,
        mapping(uint256 => mapping(address => uint256)) storage pendingUpdateIndex,
        uint256 boxId,
        uint256 idx
    ) private {
        uint256 last = pendingUpdates[boxId].length - 1;
        address removed = pendingUpdates[boxId][idx];
        if (idx != last) {
            address moved = pendingUpdates[boxId][last];
            pendingUpdates[boxId][idx] = moved;
            pendingUpdateIndex[boxId][moved] = idx + 1; // idx+1
        }
        pendingUpdates[boxId].pop();
        pendingUpdateIndex[boxId][removed] = 0;
    }

    /// @notice One-shot Box-0 subtree backfill for imported subscribers.
    ///         Iterates the slice `[startIdx, endIdx)` of `activeUsers` and
    ///         re-runs the permanent-counter propagation for any entry that
    ///         already holds Box 0. The body is inlined here (rather than
    ///         delegating to `propagateBox0Permanent`) so the deployer's
    ///         StepNet wrapper stays minimal.
    function rebuildBox0SubtreeBatch(
        mapping(address => User)    storage users,
        address[]                   storage activeUsers,
        mapping(address => uint256) storage box0LeftSubtree,
        mapping(address => uint256) storage box0RightSubtree,
        uint256 startIdx,
        uint256 endIdx
    ) external {
        uint256 cap = activeUsers.length;
        if (endIdx > cap) endIdx = cap;
        for (uint256 i = startIdx; i < endIdx;) {
            address ua = activeUsers[i];
            address current = users[ua].upline;
            if (users[ua].boxPurchasedCount[0] > 0 && current != address(0)) {
                address child = ua;
                uint256 levels = 0;
                bool isLeft = (users[current].left == child);
                while (current != address(0) && levels < IMMEDIATE_UPDATE_LEVELS) {
                    if (isLeft) box0LeftSubtree[current]++;
                    else       box0RightSubtree[current]++;
                    levels++;
                    child = current;
                    current = users[current].upline;
                    if (current != address(0)) isLeft = (users[current].left == child);
                }
            }
            unchecked { ++i; }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  Importer → StepNet interface
// ═══════════════════════════════════════════════════════════════════════════

interface IStepNetForImport {
    function importSingleUser(ImportUserData calldata d) external;
    function originalDeployer() external view returns (address);
    function initialized() external view returns (bool);
    function deployedAt() external view returns (uint256);
    function IMPORT_WINDOW() external view returns (uint256);
}

// ═══════════════════════════════════════════════════════════════════════════
//  StepNetImporter — one-shot batch-import helper. Deployed separately to
//  keep StepNet's bytecode under the EIP-170 cap. The deployer wires this
//  contract into StepNet via `setImporter`, runs the batches, then calls
//  `StepNet.finalizeSetup()` which permanently closes the import window.
//
//  Deployment order:
//    1) Deploy ReserveLib, WalletLib, PendingLib.
//    2) Deploy StepNet linked against those three libraries.
//    3) Deploy StepNetImporter with StepNet's address.
//    4) Call StepNet.setImporter(importerAddress).
//    5) Run StepNetImporter.batchImport(data) for each batch.
//    6) Call StepNet.finalizeSetup() to lock the registry.
// ═══════════════════════════════════════════════════════════════════════════

contract StepNetImporter {
    IStepNetForImport public immutable STEP_NET;
    address public immutable DEPLOYER;

    error ZeroAddress();
    error OnlyDeployer();
    error BatchSizeInvalid();
    error ImportClosed();

    constructor(address _stepNet) {
        if (_stepNet == address(0)) revert ZeroAddress();
        STEP_NET = IStepNetForImport(_stepNet);
        DEPLOYER = msg.sender;
    }

    function batchImport(ImportUserData[] calldata data) external {
        if (msg.sender != DEPLOYER) revert OnlyDeployer();
        if (STEP_NET.initialized()) revert ImportClosed();
        if (block.timestamp > STEP_NET.deployedAt() + STEP_NET.IMPORT_WINDOW()) revert ImportClosed();
        if (data.length == 0 || data.length > 150) revert BatchSizeInvalid();

        for (uint256 i = 0; i < data.length;) {
            STEP_NET.importSingleUser(data[i]);
            unchecked { ++i; }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ImportLib — bulk user-state writes for one-time migration import.
//  Deployed as a standalone external library; callers invoke via DELEGATECALL
//  so all storage updates land on StepNet, while the field-write bytecode lives
//  in the library — keeping StepNet under the EIP-170 cap. Called once per user
//  during the import window, so the delegatecall overhead is irrelevant.
// ═══════════════════════════════════════════════════════════════════════════
library ImportLib {
    uint256 private constant BOX_COUNT = 6;

    function writeUser(
        mapping(address => User)                          storage users,
        mapping(address => string)                        storage userName,
        mapping(address => mapping(uint256 => uint256))   storage pendingBoxDaiRewards,
        ImportUserData calldata d
    ) external {
        address ua = d.ua;
        User storage u = users[ua];
        u.boxPurchasedCount    = d.boxPurchasedCount;
        u.totalPaidPerBox      = d.totalPaidPerBox;
        u.totalPaidAllBoxes    = d.totalPaidAllBoxes;
        u.upline               = d.upline;
        u.left                 = d.left;
        u.right                = d.right;
        u.totalCommissionDai   = d.totalCommissionDai;
        u.reservedForUpgrade   = d.reservedForUpgrade;
        u.stepReceivedFromClub = d.stepReceivedFromClub;
        u.amountBurnedStepClub = d.amountBurnedStepClub;
        u.totalBurnedByUser    = d.totalBurnedByUser;
        u.inStepClub           = d.inStepClub;
        userName[ua]           = d.name;
        u.startTimestamp       = d.startTimestamp;
        u.reserveCycleStart    = d.reserveCycleStart;
        u.clubJoinedTimestamp  = d.clubJoinedTimestamp;

        for (uint256 b = 0; b < BOX_COUNT;) {
            u.teamLeftCount[b]          = d.teamLeftCount[b];
            u.teamRightCount[b]         = d.teamRightCount[b];
            pendingBoxDaiRewards[ua][b] = d.pendingDaiRewards[b];
            unchecked { ++b; }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
//  ClubSyncLib — one-time migration helper that re-mirrors club membership +
//  history into StepClub. Deployed standalone; StepNet invokes it via
//  DELEGATECALL so this cold loop lives off-contract, keeping StepNet under the
//  EIP-170 cap.
// ═══════════════════════════════════════════════════════════════════════════
interface IClubSync {
    function isMember(address ua) external view returns (bool);
    function addMember(address ua) external;
    function setClubHistory(address ua, uint256 received, uint256 burned) external;
}

library ClubSyncLib {
    event ClubHistorySynced(address indexed ua, uint256 received, uint256 burned);

    function sync(
        address[] storage activeUsers,
        mapping(address => User) storage users,
        IClubSync club,
        uint256 startIdx,
        uint256 endIdx
    ) external {
        uint256 total = activeUsers.length;
        if (endIdx > total || endIdx == 0) endIdx = total;
        if (startIdx >= endIdx) return;

        for (uint256 i = startIdx; i < endIdx; ) {
            address ua = activeUsers[i];

            if (users[ua].inStepClub) {
                // safety check: only add when not already a member
                bool isAlreadyMember = false;
                try club.isMember(ua) returns (bool member) {
                    isAlreadyMember = member;
                } catch {
                    isAlreadyMember = false;
                }

                if (!isAlreadyMember) {
                    try club.addMember(ua) {} catch {}
                }

                // carry over received/burned history
                uint256 received = users[ua].stepReceivedFromClub;
                uint256 burned   = users[ua].amountBurnedStepClub;

                try club.setClubHistory(ua, received, burned) {} catch {}

                emit ClubHistorySynced(ua, received, burned);
            }
            unchecked { ++i; }
        }
    }
}
