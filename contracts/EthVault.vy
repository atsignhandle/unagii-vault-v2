# @version 0.2.15

"""
@title Unagii EthVault 3.0.0
@author stakewith.us
@license AGPL-3.0-or-later
"""

from vyper.interfaces import ERC20


interface IStrategy:
    def vault() -> address: view
    def token() -> address: view
    def totalAssets() -> uint256: view
    def withdraw(amount: uint256): nonpayable


interface UnagiiToken:
    def token() -> address: view
    def totalSupply() -> uint256: view
    def mint(receiver: address, amount: uint256): nonpayable
    def burn(spender: address, amount: uint256): nonpayable
    def lastBlock(owner: address) -> uint256: view


# ERC20 selectors
TRANSFER: constant(Bytes[4]) = method_id("transfer(address,uint256)")

# maximum number of active strategies
MAX_ACTIVE: constant(uint256) = 20
MAX_TOTAL_DEBT_RATIO: constant(uint256) = 10000
MIN_RESERVE_DENOMINATOR: constant(uint256) = 10000
MAX_DEGRADATION: constant(uint256) = 10 ** 18
MAX_BLOCK_DELAY: constant(uint256) = 1000

ETH: constant(address) = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE


struct Strategy:
    approved: bool
    active: bool
    debtRatio: uint256  # ratio of total assets this strategy can borrow
    debt: uint256  # current amount borrowed


event SetNextTimeLock:
    nextTimeLock: address


event AcceptTimeLock:
    timeLock: address


event SetAdmin:
    admin: address


event SetGuardian:
    guardian: address


event SetWorker:
    worker: address


event SetPause:
    paused: bool


event SetWhitelist:
    addr: indexed(address)
    approved: bool


event Deposit:
    sender: indexed(address)
    amount: uint256
    shares: uint256


event Withdraw:
    owner: indexed(address)
    shares: uint256
    amount: uint256


event ApproveStrategy:
    strategy: indexed(address)


event RevokeStrategy:
    strategy: indexed(address)


event ActivateStrategy:
    strategy: indexed(address)


event DeactivateStrategy:
    strategy: indexed(address)


event SetActiveStrategies:
    strategies: address[MAX_ACTIVE]


event SetDebtRatios:
    debtRatios: uint256[MAX_ACTIVE]


event Borrow:
    strategy: indexed(address)
    amount: uint256


event Repay:
    strategy: indexed(address)
    amount: uint256


event Sync:
    strategy: indexed(address)
    total: uint256
    debt: uint256
    lockedProfit: uint256


event ReceiveEth:
    sender: indexed(address)
    amount: uint256


paused: public(bool)

uToken: public(UnagiiToken)
# privileges: time lock >= admin >= guardian >= worker
timeLock: public(address)
nextTimeLock: public(address)
admin: public(address)
guardian: public(address)
worker: public(address)

# numerator to calculate the minimum amount of ETH to be kept in this vault
# for cheap withdraw
minReserve: public(uint256)

totalDebt: public(uint256)  # debt to users (total borrowed by strategies)
totalDebtRatio: public(uint256)  # sum of strategy debt ratios
strategies: public(HashMap[address, Strategy])  # all strategies
activeStrategies: public(address[MAX_ACTIVE])  # list of active strategies

lastSync: public(uint256)  # timestamp of last sync
# profit locked from sync, released over time at a rate set by lockedProfitDegradation
lockedProfit: public(uint256)
# rate at which locked profit is released
# 0 = forever, MAX_DEGRADATION = 100% of profit is released 1 block after sync
lockedProfitDegradation: public(uint256)

# minimum number of block to wait before deposit / withdraw
# used to protect agains flash attacks
blockDelay: public(uint256)
# whitelisted address can bypass block delay check
whitelist: public(HashMap[address, bool])


@external
def __init__(uToken: address, guardian: address, worker: address):
    self.timeLock = msg.sender
    self.admin = msg.sender
    self.guardian = guardian
    self.worker = worker

    self.uToken = UnagiiToken(uToken)

    assert self.uToken.token() == ETH, "uToken token != ETH"

    self.paused = True
    self.blockDelay = 10
    # 6 hours
    self.lockedProfitDegradation = MAX_DEGRADATION / (3600 * 6)
    self.lastSync = block.timestamp
    # 5% of free funds
    self.minReserve = 500


@external
@payable
def __default__():
    """
    @dev Prevent users from accidentally sending ETH
    """
    assert self.strategies[msg.sender].approved or self.whitelist[msg.sender], "!whitelist"
    log ReceiveEth(msg.sender, msg.value)


@external
@view
def token() -> address:
    return ETH


@internal
def _sendEth(to: address, amount: uint256):
    assert to != ZERO_ADDRESS, "to = 0 address"
    raw_call(to, b"", value=amount)


@internal
def _safeTransfer(token: address, receiver: address, amount: uint256):
    res: Bytes[32] = raw_call(
        token,
        concat(
            TRANSFER,
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(res) > 0:
        assert convert(res, bool), "transfer failed"


@external
def setNextTimeLock(nextTimeLock: address):
    """
    @notice Set next time lock
    @param nextTimeLock Address of next time lock
    """
    assert msg.sender == self.timeLock, "!time lock"
    self.nextTimeLock = nextTimeLock
    log SetNextTimeLock(nextTimeLock)


@external
def acceptTimeLock():
    """
    @notice Accept time lock
    @dev Only `nextTimeLock` can claim time lock
    """
    assert msg.sender == self.nextTimeLock, "!next time lock"
    self.timeLock = msg.sender
    self.nextTimeLock = ZERO_ADDRESS
    log AcceptTimeLock(msg.sender)


@external
def setAdmin(admin: address):
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self.admin = admin
    log SetAdmin(admin)


@external
def setGuardian(guardian: address):
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self.guardian = guardian
    log SetGuardian(guardian)


@external
def setWorker(worker: address):
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self.worker = worker
    log SetWorker(worker)


@external
def setPause(paused: bool):
    assert msg.sender in [self.timeLock, self.admin, self.guardian], "!auth"
    self.paused = paused
    log SetPause(paused)


@external
def setMinReserve(minReserve: uint256):
    """
    @notice Set minimum amount of ETH reserved in this vault for cheap
            withdrawn by user
    @param minReserve Numerator to calculate min reserve
           0 - all funds can be transferred to strategies
           MIN_RESERVE_DENOMINATOR - no funds can be transferred to strategies
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert minReserve <= MIN_RESERVE_DENOMINATOR, "min reserve > max"
    self.minReserve = minReserve


@external
def setLockedProfitDegradation(degradation: uint256):
    """
    @notice Set locked profit degradation (rate locked profit is released)
    @param degradation Rate of degradation
           0 - profit is locked forever
           MAX_DEGRADATION - 100% of profit is released 1 block after sync
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert degradation <= MAX_DEGRADATION, "degradation > max"
    self.lockedProfitDegradation = degradation


@external
def setBlockDelay(delay: uint256):
    """
    @notice Set block delay, used to protect against flash attacks
    @param delay Number of blocks to delay before user can deposit / withdraw
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert delay >= 1 and delay <= MAX_BLOCK_DELAY, "delay out of range"
    self.blockDelay = delay


@external
def setWhitelist(addr: address, approved: bool):
    """
    @notice Approve or disapprove address to skip check on block delay.
            Approved address can deposit, withdraw and transfer uToken in
            a single transaction
    @param approved Boolean
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self.whitelist[addr] = approved
    log SetWhitelist(addr, approved)


@internal
@view
def _totalAssets() -> uint256:
    """
    @notice Total amount of ETH in this vault + amount in strategies
    @dev Returns total amount of ETH locked in this contract
    """
    return self.balance + self.totalDebt


@external
@view
def totalAssets() -> uint256:
    return self._totalAssets()


@internal
@view
def _calcLockedProfit() -> uint256:
    """
    @notice Calculated locked profit
    @dev Returns amount of profit locked from last sync. Profit is released
         over time, depending on the release rate `lockedProfitDegradation`.
         Profit is locked after `sync` to protect against sandwich attack.
    """
    lockedFundsRatio: uint256 = (
        block.timestamp - self.lastSync
    ) * self.lockedProfitDegradation

    if lockedFundsRatio < MAX_DEGRADATION:
        lockedProfit: uint256 = self.lockedProfit
        return lockedProfit - lockedFundsRatio * lockedProfit / MAX_DEGRADATION
    else:
        return 0


@external
@view
def calcLockedProfit() -> uint256:
    return self._calcLockedProfit()


@internal
@view
def _calcFreeFunds() -> uint256:
    """
    @notice Calculate free funds (total assets - locked profit)
    @dev Returns total amount of ETH that can be withdrawn
    """
    return self._totalAssets() - self._calcLockedProfit()


@external
@view
def calcFreeFunds() -> uint256:
    return self._calcFreeFunds()


@internal
@view
def _calcMinReserve(freeFunds: uint256) -> uint256:
    """
    @notice Calculates minimum amount of ETH that is reserved in vault for
            cheap withdraw
    @param freeFunds Free funds
    @dev Returns min reserve
    """
    return freeFunds * self.minReserve / MIN_RESERVE_DENOMINATOR


@external
@view
def calcMinReserve() -> uint256:
    return self._calcMinReserve(self._calcFreeFunds())


@internal
@pure
def _calcSharesToMint(
    amount: uint256, totalSupply: uint256, freeFunds: uint256
) -> uint256:
    """
    @notice Calculate uToken shares to mint
    @param amount Amount of ETH to deposit
    @param totalSupply Total amount of shares
    @param freeFunds Free funds before deposit
    @dev Returns amount of uToken to mint. Input must be numbers before deposit
    @dev Calculated with `freeFunds`, not `totalAssets`
    """
    # s = shares to mint
    # T = total shares before mint
    # a = deposit amount
    # P = total amount of ETH in vault + strategies before deposit
    # s / (T + s) = a / (P + a)
    # sP = aT
    # a = 0               | mint s = 0
    # a > 0, T = 0, P = 0 | mint s = a
    # a > 0, T = 0, P > 0 | mint s = a as if P = 0
    # a > 0, T > 0, P = 0 | invalid, equation cannot be true for any s
    # a > 0, T > 0, P > 0 | mint s = aT / P
    if totalSupply > 0:
        # reverts if free funds = 0
        return amount * totalSupply / freeFunds
    return amount


@external
@view
def calcSharesToMint(amount: uint256) -> uint256:
    return self._calcSharesToMint(
        amount, self.uToken.totalSupply(), self._calcFreeFunds()
    )


@external
@payable
@nonreentrant("lock")
def deposit(_min: uint256) -> uint256:
    """
    @notice Deposit ETH into vault
    @param _min Minimum amount of shares to be minted
    @dev Returns actual amount of shares minted
    """
    assert not self.paused, "paused"
    assert msg.value > 0, "deposit = 0"

    # check whitelisted or block delay
    assert (
        self.whitelist[msg.sender]
        or block.number >= self.uToken.lastBlock(msg.sender) + self.blockDelay
    ), "block < delay"

    totalSupply: uint256 = self.uToken.totalSupply()
    freeFunds: uint256 = self._calcFreeFunds() - msg.value

    # calculate with free funds before deposit
    shares: uint256 = self._calcSharesToMint(msg.value, totalSupply, freeFunds)
    assert shares >= _min, "shares < min"

    self.uToken.mint(msg.sender, shares)

    log Deposit(msg.sender, msg.value, shares)

    return shares


@internal
@pure
def _calcWithdraw(shares: uint256, totalSupply: uint256, freeFunds: uint256) -> uint256:
    """
    @notice Calculate amount of ETH to withdraw
    @param shares Amount of uToken shares to burn
    @param totalSupply Total amount of shares before burn
    @param freeFunds Free funds
    @dev Returns amount of ETH to withdraw
    @dev Calculated with `freeFunds`, not `totalAssets`
    """
    # s = shares
    # T = total supply of shares
    # a = amount to withdraw
    # P = total amount of ETH in vault + strategies
    # s / T = a / P (constraints T >= s, P >= a)
    # sP = aT
    # s = 0               | a = 0
    # s > 0, T = 0, P = 0 | invalid (violates constraint T >= s)
    # s > 0, T = 0, P > 0 | invalid (violates constraint T >= s)
    # s > 0, T > 0, P = 0 | a = 0
    # s > 0, T > 0, P > 0 | a = sP / T

    # invalid if total supply = 0
    return shares * freeFunds / totalSupply


@external
@view
def calcWithdraw(shares: uint256) -> uint256:
    return self._calcWithdraw(shares, self.uToken.totalSupply(), self._calcFreeFunds())


@external
@nonreentrant("lock")
def withdraw(shares: uint256, _min: uint256):
    """
    @notice Withdraw ETH from vault
    @param shares Amount of uToken to burn
    @param _min Minimum amount of ETH that msg.sender will receive
    """
    assert shares > 0, "shares = 0"

    # check whitelisted or block delay
    assert (
        self.whitelist[msg.sender]
        or block.number >= self.uToken.lastBlock(msg.sender) + self.blockDelay
    ), "block < delay"

    amount: uint256 = self._calcWithdraw(
        shares, self.uToken.totalSupply(), self._calcFreeFunds()
    )

    # withdraw from strategies if amount to withdraw > balance of vault
    bal: uint256 = self.balance
    if amount > bal:
        for strat in self.activeStrategies:
            # reached end of active strategies
            if strat == ZERO_ADDRESS:
                break

            # done withdrawing
            if bal >= amount:
                break

            debt: uint256 = self.strategies[strat].debt
            need: uint256 = min(amount - bal, debt)
            if need > 0:
                IStrategy(strat).withdraw(need)
                diff: uint256 = self.balance - bal
                bal += diff  # = self.balance

                self.strategies[strat].debt -= diff
                self.totalDebt -= diff

                # calculate loss
                total: uint256 = IStrategy(strat).totalAssets() + diff
                if total < debt:
                    loss: uint256 = debt - total
                    self.strategies[strat].debt -= loss
                    self.totalDebt -= loss
                    amount -= loss

        if amount > bal:
            amount = bal

    self.uToken.burn(msg.sender, shares)

    assert amount >= _min, "amount < min"
    self._sendEth(msg.sender, amount)

    log Withdraw(msg.sender, shares, amount)


# array functions see test/ArrayTest.vy for tests
@internal
def _pack():
    """
    @dev Pack array elements to left
         example
         before [1, 2, 0, 0, 3]
         after  [1, 2, 3, 0, 0]
    """
    arr: address[MAX_ACTIVE] = empty(address[MAX_ACTIVE])
    i: uint256 = 0
    for strat in self.activeStrategies:
        if strat != ZERO_ADDRESS:
            arr[i] = strat
            i += 1
    self.activeStrategies = arr


@internal
def _append(strategy: address):
    assert self.activeStrategies[MAX_ACTIVE - 1] == ZERO_ADDRESS, "active > max"
    self.activeStrategies[MAX_ACTIVE - 1] = strategy
    self._pack()


@internal
def _remove(i: uint256):
    assert i < MAX_ACTIVE, "i >= max"
    assert self.activeStrategies[i] != ZERO_ADDRESS, "zero address"
    self.activeStrategies[i] = ZERO_ADDRESS
    self._pack()


@internal
@view
def _find(strategy: address) -> uint256:
    for i in range(MAX_ACTIVE):
        if self.activeStrategies[i] == strategy:
            return i
    raise "not found"


@external
def approveStrategy(strategy: address):
    """
    @notice Approve strategy
    @param strategy Address of strategy
    """
    assert msg.sender == self.timeLock, "!time lock"

    assert not self.strategies[strategy].approved, "approved"
    assert IStrategy(strategy).vault() == self, "strategy vault != vault"
    assert IStrategy(strategy).token() == ETH, "strategy token != ETH"

    self.strategies[strategy] = Strategy(
        {
            approved: True,
            active: False,
            debtRatio: 0,
            debt: 0,
        }
    )

    log ApproveStrategy(strategy)


@external
def revokeStrategy(strategy: address):
    """
    @notice Disapprove strategy
    @param strategy Address of strategy
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert self.strategies[strategy].approved, "!approved"
    assert not self.strategies[strategy].active, "active"

    self.strategies[strategy].approved = False
    log RevokeStrategy(strategy)


@external
def activateStrategy(strategy: address, debtRatio: uint256):
    """
    @notice Activate strategy
    @param strategy Address of strategy
    @param debtRatio Ratio of total assets of vault that strategy can borrow
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert self.strategies[strategy].approved, "!approved"
    assert not self.strategies[strategy].active, "active"

    self._append(strategy)
    self.strategies[strategy].active = True
    self.strategies[strategy].debtRatio = debtRatio

    self.totalDebtRatio += debtRatio
    assert self.totalDebtRatio <= MAX_TOTAL_DEBT_RATIO, "debt ratio > max"

    log ActivateStrategy(strategy)


@external
def deactivateStrategy(strategy: address):
    """
    @notice Deactivate strategy
    @param strategy Addres of strategy
    """
    assert msg.sender in [self.timeLock, self.admin, self.guardian], "!auth"
    assert self.strategies[strategy].active, "!active"

    self._remove(self._find(strategy))
    self.strategies[strategy].active = False
    self.totalDebtRatio -= self.strategies[strategy].debtRatio
    self.strategies[strategy].debtRatio = 0

    log DeactivateStrategy(strategy)


@external
def setActiveStrategies(strategies: address[MAX_ACTIVE]):
    """
    @notice Reorder active strategies
    @param strategies Array of active strategies
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"

    for i in range(MAX_ACTIVE):
        old: address = self.activeStrategies[i]
        new: address = strategies[i]

        # check old and new strategies have the same number of strategies
        if old == ZERO_ADDRESS:
            assert new == ZERO_ADDRESS, "new != zero address"
        else:
            assert new != ZERO_ADDRESS, "new = zero address"

            # Check new strategy is active and no duplicate
            # assert will fail if duplicate strategy in new strategies
            assert self.strategies[new].active, "!active"
            self.strategies[new].active = False

    # update active strategies
    for i in range(MAX_ACTIVE):
        new: address = strategies[i]
        if new == ZERO_ADDRESS:
            break
        self.strategies[new].active = True
        self.activeStrategies[i] = new

    log SetActiveStrategies(strategies)


@external
def setDebtRatios(debtRatios: uint256[MAX_ACTIVE]):
    """
    @notice Update debt ratios of active strategies
    @param debtRatios Array of debt ratios
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"

    # use memory to save gas
    totalDebtRatio: uint256 = 0
    for i in range(MAX_ACTIVE):
        strat: address = self.activeStrategies[i]
        if strat == ZERO_ADDRESS:
            break

        self.strategies[strat].debtRatio = debtRatios[i]
        totalDebtRatio += debtRatios[i]

    self.totalDebtRatio = totalDebtRatio
    assert self.totalDebtRatio <= MAX_TOTAL_DEBT_RATIO, "total > max"

    log SetDebtRatios(debtRatios)


@internal
@view
def _calcMaxBorrow(strategy: address) -> uint256:
    """
    @notice Calculate how much ETH strategy can borrow
    @param strategy Address of strategy
    @dev Returns amount of ETH that `strategy` can borrow
    """
    if self.paused or self.totalDebtRatio == 0:
        return 0

    bal: uint256 = self.balance
    freeFunds: uint256 = self._calcFreeFunds()
    minReserve: uint256 = self._calcMinReserve(freeFunds)
    if bal <= minReserve:
        return 0

    # min reserve <= free funds
    # strategy debtRatio = 0 if strategy is not active
    limit: uint256 = (freeFunds - minReserve) * self.strategies[strategy].debtRatio / self.totalDebtRatio
    debt: uint256 = self.strategies[strategy].debt

    if debt >= limit:
        return 0

    # minimum of debt limit and ETH available in this vault
    return min(limit - debt, bal - minReserve)


@external
@view
def calcMaxBorrow(strategy: address) -> uint256:
    return self._calcMaxBorrow(strategy)


@external
def borrow(amount: uint256):
    """
    @notice Borrow ETH from vault
    @param amount Amount of ETH to borrow
    @dev Only active strategy can borrow
    """
    assert self.strategies[msg.sender].active, "!active strategy"

    available: uint256 = self._calcMaxBorrow(msg.sender)
    _amount: uint256 = min(amount, available)
    assert _amount > 0, "borrow = 0"

    self._sendEth(msg.sender, _amount)

    self.totalDebt += _amount
    self.strategies[msg.sender].debt += _amount

    log Borrow(msg.sender, _amount)


@external
@payable
def repay():
    """
    @notice Repay ETH to vault
    @dev Only approved and active strategy can repay
    """
    assert self.strategies[msg.sender].approved, "!approved strategy"
    assert msg.value > 0, "repay = 0"

    self.totalDebt -= msg.value
    self.strategies[msg.sender].debt -= msg.value

    log Repay(msg.sender, msg.value)


@external
def sync(strategy: address, minTotal: uint256, maxTotal: uint256):
    """
    @notice Update debt of strategy based on total asset of strategy
    @param strategy Address of active strategy
    @param minTotal Minimum of total asset of strategy
    @param maxTotal Maximum of total asset of strategy
    @dev `minTotal` and `maxTotal` are used to make sure total asset is within
          a reasonable range
    """
    assert msg.sender in [self.worker, self.admin, self.timeLock], "!auth"
    assert self.strategies[strategy].active, "!active strategy"

    debt: uint256 = self.strategies[strategy].debt
    total: uint256 = IStrategy(strategy).totalAssets()

    assert total >= minTotal and total <= maxTotal, "total out of range"

    gain: uint256 = 0
    loss: uint256 = 0
    locked: uint256 = self._calcLockedProfit()

    if total > debt:
        gain = total - debt
        self.lockedProfit = locked + gain

        self.strategies[strategy].debt += gain
        self.totalDebt += gain
    elif total < debt:
        loss = debt - total
        if loss > locked:
            self.lockedProfit = 0
        else:
            self.lockedProfit -= loss

        self.strategies[strategy].debt -= loss
        self.totalDebt -= loss

    self.lastSync = block.timestamp

    # log debt before update, so gain and loss can be computed offchain
    log Sync(strategy, total, debt, self.lockedProfit)


@external
def sweep(token: address):
    """
    @notice Transfer any token accidentally sent to this contract
            to admin or time lock
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self._safeTransfer(token, msg.sender, ERC20(token).balanceOf(self))
