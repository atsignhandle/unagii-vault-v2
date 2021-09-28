# @version 0.2.15

"""
@title Unagii Vault V2 1.0.0
@author stakewith.us
@license AGPL-3.0-or-later
"""

from vyper.interfaces import ERC20

# ERC20 selectors
APPROVE: constant(Bytes[4]) = method_id("approve(address,uint256)")
TRANSFER: constant(Bytes[4]) = method_id("transfer(address,uint256)")
TRANSFER_FROM: constant(Bytes[4]) = method_id("transferFrom(address,address,uint256)")

# maximum number of active strategies
MAX_QUEUE: constant(uint256) = 20
MAX_TOTAL_DEBT_RATIO: constant(uint256) = 10000
MAX_MIN_RESERVE: constant(uint256) = 10000
MAX_DEGRADATION: constant(uint256) = 10 ** 18

struct Strategy:
    approved: bool
    active: bool
    debtRatio: uint256  # ratio of total assets this strategy can borrow
    debt: uint256  # current amount borrowed


interface IStrategy:
    def vault() -> address: view
    def token() -> address: view
    def totalAssets() -> uint256: view
    def withdraw(amount: uint256) -> uint256: nonpayable
    def migrate(newVersion: address): nonpayable


interface DetailedERC20:
    def decimals() -> uint256: view


interface UnagiiToken:
    def minter() -> address: view
    def token() -> address: view
    def decimals() -> uint256: view
    def totalSupply() -> uint256: view
    def balanceOf(owner: address) -> uint256: view
    def mint(receiver: address, amount: uint256): nonpayable
    def burn(spender: address, amount: uint256): nonpayable
    def lastBlock(owner: address) -> uint256: view


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
    diff: uint256
    shares: uint256


event Withdraw:
    owner: indexed(address)
    shares: uint256
    amount: uint256


event Borrow:
    strategy: indexed(address)
    amount: uint256


event Repay:
    strategy: indexed(address)
    amount: uint256


event Sync:
    strategy: indexed(address)
    balanceOfVault: uint256
    debt: uint256
    totalInStrategy: uint256
    gain: uint256
    loss: uint256
    lockedProfit: uint256


event ApproveStrategy:
    strategy: indexed(address)


event RevokeStrategy:
    strategy: indexed(address)


event ActivateStrategy:
    strategy: indexed(address)


event DeactivateStrategy:
    strategy: indexed(address)


event SetQueue:
    queue: address[MAX_QUEUE]


event SetDebtRatios:
    debtRatios: uint256[MAX_QUEUE]


event MigrateStrategy:
    oldStrategy: indexed(address)
    newStrategy: indexed(address)


event ForceUpdateBalanceOfVault:
    balanceOfVault: uint256


paused: public(bool)

token: public(ERC20)
uToken: public(UnagiiToken)
# privileges: time lock >= admin >= guardian >= worker
timeLock: public(address)
nextTimeLock: public(address)
admin: public(address)
guardian: public(address)
worker: public(address)

# token balance of vault tracked internally to protect against share dilution
# from sending tokens directly to this contract
balanceOfVault: public(uint256)
debt: public(uint256)  # debt to users (amount borrowed by strategies)
# minimum amount of token to be kept in this vault for cheap withdraw
minReserve: public(uint256)
# timestamp of last sync
lastSync: public(uint256)
# profit locked from report, released over time at a rate set by lockedProfitDegradation
lockedProfit: public(uint256)
# rate at which locked profit is released
# 0 = forever, MAX_DEGREDATION = 100% of profit is released 1 block after report
lockedProfitDegradation: public(uint256)
# minimum number of block to wait before deposit / withdraw
# used to protect agains flash attacks
blockDelay: public(uint256)
# whitelisted address can bypass block delay check
whitelist: public(HashMap[address, bool])

totalDebtRatio: public(uint256)
strategies: public(HashMap[address, Strategy])  # all strategies
queue: public(address[MAX_QUEUE])  # list of active strategies

# TODO: migrate

@external
def __init__(token: address, uToken: address):
    self.timeLock = msg.sender
    self.admin = msg.sender
    self.guardian = msg.sender
    self.worker = msg.sender

    self.token = ERC20(token)
    self.uToken = UnagiiToken(uToken)

    assert self.uToken.token() == self.token.address, "uToken token != token"

    self.paused = True
    self.blockDelay = 1
    # 6 hours
    self.lockedProfitDegradation = convert(MAX_DEGRADATION / (3600 * 6), uint256)


@internal
def _safeApprove(token: address, spender: address, amount: uint256):
    res: Bytes[32] = raw_call(
        token,
        concat(
            APPROVE,
            convert(spender, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(res) > 0:
        assert convert(res, bool), "approve failed"


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


@internal
def _safeTransferFrom(
    token: address, owner: address, receiver: address, amount: uint256
):
    res: Bytes[32] = raw_call(
        token,
        concat(
            TRANSFER_FROM,
            convert(owner, bytes32),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
    )
    if len(res) > 0:
        assert convert(res, bool), "transferFrom failed"


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
    @notice Set minimum amount of token reserved in this vault for cheap
            withdrawn by user
    @param minReserve Numerator to calculate min reserve
           0 = all funds can be transferred to fund manager
           MAX_MIN_RESERVE = 0 tokens can be transferred to fund manager
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert minReserve <= MAX_MIN_RESERVE, "min reserve > max"
    self.minReserve = minReserve


@external
def setLockedProfitDegradation(degradation: uint256):
    """
    @notice Set locked profit degradation (rate locked profit is released)
    @param degradation Rate of degradation
                 0 = profit is locked forever
                 MAX_DEGRADATION = 100% of profit is released 1 block after report
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
    assert delay >= 1, "delay = 0"
    self.blockDelay = delay


@external
def setWhitelist(addr: address, approved: bool):
    """
    @notice Approve or disapprove address to skip check on block delay.
            Approved address can deposit, withdraw and transfer uToken in
            a single transaction
    @param approved Boolean True = approve
                             False = disapprove
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    self.whitelist[addr] = approved
    log SetWhitelist(addr, approved)


@internal
@view
def _totalAssets() -> uint256:
    """
    @notice Total amount of token in this vault + amount in strategies
    @dev State variable `balanceOfVault` is used to track balance of token in
         this contract instead of `token.balanceOf(self)`. This is done to
         protect against uToken shares being diluted by directly sending token
         to this contract.
    @dev Returns total amount of token in this contract
    """
    return self.balanceOfVault + self.debt


@external
@view
def totalAssets() -> uint256:
    return self._totalAssets()


@internal
@view
def _calcLockedProfit() -> uint256:
    """
    @notice Calculated locked profit
    @dev Returns amount of profit locked from last report. Profit is released
         over time, depending on the release rate `lockedProfitDegradation`.
         Profit is locked after `report` to protect against sandwich attack.
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
    @dev Returns total amount of tokens that can be withdrawn
    """
    return self._totalAssets() - self._calcLockedProfit()


@external
@view
def calcFreeFunds() -> uint256:
    return self._calcFreeFunds()


@internal
@pure
def _calcSharesToMint(
    amount: uint256, totalSupply: uint256, freeFunds: uint256
) -> uint256:
    """
    @notice Calculate uToken shares to mint
    @param amount Amount of token to deposit
    @param totalSupply Total amount of shares
    @param freeFunds Free funds before deposit
    @dev Returns amount of uToken to mint. Input must be numbers before deposit
    @dev Calculated with `freeFunds`, not `totalAssets`
    """
    # s = shares to mint
    # T = total shares before mint
    # a = deposit amount
    # P = total amount of token in vault + strategies before deposit
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
@nonreentrant("lock")
def deposit(amount: uint256, _min: uint256) -> uint256:
    """
    @notice Deposit token into vault
    @param amount Amount of token to deposit
    @param _min Minimum amount of uToken to be minted
    @dev Returns actual amount of uToken minted
    """
    assert not self.paused, "paused"
    assert amount > 0, "deposit = 0"

    # TODO: assert self.token.balanceOf(self) >= self.balanceOfVault

    # check block delay or whitelisted
    assert (
        block.number >= self.uToken.lastBlock(msg.sender) + self.blockDelay
        or self.whitelist[msg.sender]
    ), "block < delay"

    totalSupply: uint256 = self.uToken.totalSupply()
    freeFunds: uint256 = self._calcFreeFunds()

    bal: uint256 = self.token.balanceOf(self)
    self._safeTransferFrom(self.token.address, msg.sender, self, amount)
    diff: uint256 = self.token.balanceOf(self) - bal

    # calculate with free funds before deposit
    shares: uint256 = self._calcSharesToMint(diff, totalSupply, freeFunds)
    assert shares >= _min, "shares < min"

    # update balanceOfVault after amount of shares is computed
    self.balanceOfVault = bal + diff
    self.uToken.mint(msg.sender, shares)

    log Deposit(msg.sender, amount, diff, shares)

    return shares


@internal
@pure
def _calcWithdraw(shares: uint256, totalSupply: uint256, freeFunds: uint256) -> uint256:
    """
    @notice Calculate amount of token to withdraw
    @param shares Amount of uToken shares to burn
    @param totalSupply Total amount of shares before burn
    @param freeFunds Free funds
    @dev Returns amount of token to withdraw
    @dev Calculated with `freeFunds`, not `totalAssets`
    """
    # s = shares
    # T = total supply of shares
    # a = amount to withdraw
    # P = total amount of token in vault + strategies
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


@internal
def _withdraw(amount: uint256) -> uint256:
    """
    @notice Withdraw `token` from active strategies
    @param amount Amount of `token` to withdraw
    @dev Returns sum of losses from active strategies
    """
    _amount: uint256 = amount
    loss: uint256 = 0
    # TODO: assert self.token.balanceOf(self) >= self.balanceOfVault
    bal: uint256 = self.token.balanceOf(self)

    for strat in self.queue:
        # reached end of queue
        if strat == ZERO_ADDRESS:
            break

        # done withdrawing
        if bal >= _amount:
            break
        
        need: uint256 = min(_amount - bal, self.strategies[strat].debt)
        if need == 0:
            continue

        _loss: uint256 = IStrategy(strat).withdraw(need)
        diff: uint256 = self.token.balanceOf(self) - bal

        if _loss > 0:
            self.strategies[strat].debt -= _loss
            loss += _loss
            _amount -= _loss
        
        self.strategies[strat].debt -= diff
        bal += diff # = self.token.balanceOf(self)
    
    if loss > 0:
        self.debt -= loss
    
    self.balanceOfVault = bal # = self.token.balanceOf(self)
    
    return loss


@external
@nonreentrant("lock")
def withdraw(shares: uint256, _min: uint256) -> uint256:
    """
    @notice Withdraw token from vault
    @param shares Amount of uToken to burn
    @param _min Minimum amount of token that msg.sender will receive
    @dev Returns actual amount of token transferred to msg.sender
    """
    assert shares > 0, "shares = 0"

    # check block delay or whitelisted
    assert (
        block.number >= self.uToken.lastBlock(msg.sender) + self.blockDelay
        or self.whitelist[msg.sender]
    ), "block < delay"

    # TODO: assert self.token.balanceOf(self) >= self.balanceOfVault

    amount: uint256 = self._calcWithdraw(
        shares, self.uToken.totalSupply(), self._calcFreeFunds()
    )

    # withdraw from strategies if amount to withdraw > balance of vault
    if amount > self.balanceOfVault:
        loss: uint256 = self._withdraw(amount - self.balanceOfVault)

        if loss > 0:
            # msg.sender must cover all of loss
            amount -= loss

        if amount > self.balanceOfVault:
            amount = self.balanceOfVault

    self.uToken.burn(msg.sender, shares)

    assert amount >= _min, "amount < min"
    self.balanceOfVault -= amount

    self._safeTransfer(self.token.address, msg.sender, amount)

    log Withdraw(msg.sender, shares, amount)

    return amount


@internal
@view
def _calcMinReserve() -> uint256:
    """
    @notice Calculate minimum amount of token that is reserved in vault for
            cheap withdraw by users
    @dev Returns min reserve
    """
    freeFunds: uint256 = self._calcFreeFunds()
    return freeFunds * self.minReserve / MAX_MIN_RESERVE


@external
@view
def calcMinReserve() -> uint256:
    return self._calcMinReserve()


@internal
@view
def _calcMaxBorrow(strategy: address) -> uint256:
    """
    @notice Calculate how much `token` strategy can borrow
    @param strategy Address of strategy
    @dev Returns amount of `token` that `strategy` can borrow
    """
    if self.paused or self.totalDebtRatio == 0:
        return 0
    
    minReserve: uint256 = self._calcMinReserve()
    if self.balanceOfVault <= minReserve:
        return 0
    
    free: uint256 = self.balanceOfVault - minReserve

    # strategy debtRatio > 0 only if strategy is active
    limit: uint256 = (
        self.strategies[strategy].debtRatio * free / self.totalDebtRatio
    )
    debt: uint256 = self.strategies[strategy].debt

    if debt >= limit:
        return 0

    return limit - debt


@external
@view
def calcMaxBorrow(strategy: address) -> uint256:
    return self._calcMaxBorrow(strategy)


@external
def borrow(amount: uint256) -> uint256:
    """
    @notice Borrow token from vault
    @dev Only active strategy can borrow
    @dev Returns amount that was sent
    """
    assert self.strategies[msg.sender].active, "!active"

    available: uint256 = self._calcMaxBorrow(msg.sender)
    _amount: uint256 = min(amount, available)
    assert _amount > 0, "borrow = 0"

    self._safeTransfer(self.token.address, msg.sender, _amount)

    self.balanceOfVault -= amount
    # include fee on trasfer to debt
    self.debt += amount
    self.strategies[msg.sender].debt += amount

    log Borrow(msg.sender, _amount)

    return _amount


@external
def repay(amount: uint256) -> uint256:
    """
    @notice Repay token to vault
    @dev Only approved and active strategy can repay
    @dev Returns actual amount that was repaid
    """
    assert self.strategies[msg.sender].approved, "!strategy"

    assert amount > 0, "repay = 0"

    bal: uint256 = self.token.balanceOf(self)
    self._safeTransferFrom(self.token.address, msg.sender, self, amount)
    diff: uint256 = self.token.balanceOf(self) - bal

    self.balanceOfVault = bal + diff
    # exclude fee on transfer from debt payment
    self.debt -= diff
    self.strategies[msg.sender].debt -= diff

    log Repay(msg.sender, diff)

    return diff


@external
def sync(strategy: address, minTotal: uint256, maxTotal: uint256):
    assert msg.sender in [self.worker, self.admin, self.timeLock], "!auth"
    assert self.strategies[strategy].active, "!active"

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
        self.debt += gain
    elif total < debt:
        loss = debt - total
        if loss > locked:
            self.lockedProfit = 0
        else:
            self.lockedProfit -= loss

        self.strategies[strategy].debt -= loss
        self.debt -= loss

    self.lastSync = block.timestamp

    log Sync(
        strategy, self.balanceOfVault, self.debt, total, gain, loss, self.lockedProfit
    )


# array functions tested in test/Array.vy
@internal
def _pack():
    """
    @dev Pack array elements to left
         example
         before [1, 2, 0, 0, 3]
         after  [1, 2, 3, 0, 0]
    """
    arr: address[MAX_QUEUE] = empty(address[MAX_QUEUE])
    i: uint256 = 0
    for strat in self.queue:
        if strat != ZERO_ADDRESS:
            arr[i] = strat
            i += 1
    self.queue = arr


@internal
def _append(strategy: address):
    assert self.queue[MAX_QUEUE - 1] == ZERO_ADDRESS, "queue > max"
    self.queue[MAX_QUEUE - 1] = strategy
    self._pack()


@internal
def _remove(i: uint256):
    assert i < MAX_QUEUE, "i >= max"
    assert self.queue[i] != ZERO_ADDRESS, "zero address"
    self.queue[i] = ZERO_ADDRESS
    self._pack()


@internal
@view
def _find(strategy: address) -> uint256:
    for i in range(MAX_QUEUE):
        if self.queue[i] == strategy:
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
    assert IStrategy(strategy).token() == self.token.address, "strategy token != token"

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
    @param debtRatio Ratio of total assets this strategy can borrow
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
def setQueue(queue: address[MAX_QUEUE]):
    """
    @notice Reorder queue
    @param queue Array of active strategies
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"

    for i in range(MAX_QUEUE):
        old: address = self.queue[i]
        new: address = queue[i]

        # check old and new queue have the same number of strategies
        if old == ZERO_ADDRESS:
            assert new == ZERO_ADDRESS, "new != zero address"
        else:
            assert new != ZERO_ADDRESS, "new = zero address"
        
            # Check new strategy is active and no duplicate
            # assert will fail if duplicate strategy in new queue
            assert self.strategies[new].active, "!active"
            self.strategies[new].active = False

    # update queue
    for i in range(MAX_QUEUE):
        new: address = queue[i]
        if new == ZERO_ADDRESS:
            break
        self.strategies[new].active = True
        self.queue[i] = new

    log SetQueue(queue)


@external
def setDebtRatios(debtRatios: uint256[MAX_QUEUE]):
    """
    @notice Update debt ratios of active strategies
    @param debtRatios Array of debt ratios
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"

    # use memory to save gas
    totalDebtRatio: uint256 = 0
    for i in range(MAX_QUEUE):
        strat: address = self.queue[i]
        if strat == ZERO_ADDRESS:
            break

        self.strategies[strat].debtRatio = debtRatios[i]
        totalDebtRatio += debtRatios[i]

    self.totalDebtRatio = totalDebtRatio
    assert self.totalDebtRatio <= MAX_TOTAL_DEBT_RATIO, "total > max"

    log SetDebtRatios(debtRatios)


@external
def migrateStrategy(old: address, new: address):
    """
    @notice Migrate strategy
    @param old Address of current strategy
    @param new Address of new strategy
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert self.strategies[old].active, "old !active"
    assert self.strategies[new].approved, "new !approved"
    assert not self.strategies[new].active, "new active"
    assert self.strategies[new].debt == 0, "new debt != 0"

    self.strategies[new] = Strategy(
        {
            approved: True,
            active: True,
            debtRatio: self.strategies[old].debtRatio,
            debt: self.strategies[old].debt,
        }
    )

    self.strategies[old].active = False
    self.strategies[old].debtRatio = 0
    self.strategies[old].debt = 0

    self.queue[self._find(old)] = new

    IStrategy(old).migrate(new)
    log MigrateStrategy(old, new)


@external
def forceUpdateBalanceOfVault():
    """
    @notice Force `balanceOfVault` to equal `token.balanceOf(self)`
    @dev Only use in case of emergency if `balanceOfVault` is > actual balance
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"

    bal: uint256 = self.token.balanceOf(self)
    assert bal < self.balanceOfVault, "bal >= vault"

    self.balanceOfVault = bal
    log ForceUpdateBalanceOfVault(bal)


@external
def sweep(token: address):
    """
    @notice Transfer any token (except `token`) accidentally sent to this contract
            to admin or time lock
    @dev Cannot transfer `token`
    """
    assert msg.sender in [self.timeLock, self.admin], "!auth"
    assert token != self.token.address, "protected"
    self._safeTransfer(token, msg.sender, ERC20(token).balanceOf(self))
