# @version 0.2.15

from vyper.interfaces import ERC20

token: public(ERC20)

## test helpers ##
maxBorrow: public(uint256)
maxRepay: public(uint256)
gain: public(uint256)
loss: public(uint256)


@external
def __init__(token: address):
    self.token = ERC20(token)
    self.maxBorrow = MAX_UINT256
    self.maxRepay = MAX_UINT256


@external
def borrow(_amount: uint256) -> uint256:
    amount: uint256 = min(_amount, self.maxBorrow)
    self.token.transfer(msg.sender, amount)
    return amount


@external
def repay(_amount: uint256) -> uint256:
    amount: uint256 = min(_amount, self.maxRepay)
    self.token.transferFrom(msg.sender, self, amount)
    return amount


## test helpers ##
@external
def setToken(token: address):
    self.token = ERC20(token)


@external
def setMaxBorrow(maxBorrow: uint256):
    self.maxBorrow = maxBorrow


@external
def setMaxRepay(maxRepay: uint256):
    self.maxRepay = maxRepay
