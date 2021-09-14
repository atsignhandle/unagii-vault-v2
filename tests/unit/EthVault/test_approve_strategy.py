import brownie
from brownie import ZERO_ADDRESS


ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"


def test_approve_strategy(ethVault, testStrategyEth, user):
    vault = ethVault
    strategy = testStrategyEth
    timeLock = vault.timeLock()

    # revert if not time lock
    with brownie.reverts("!time lock"):
        vault.approveStrategy(strategy, {"from": user})

    # revert if strategy.vault != vault
    strategy._setVault_(ZERO_ADDRESS)
    with brownie.reverts("strategy vault != vault"):
        vault.approveStrategy(strategy, {"from": timeLock})

    strategy._setVault_(vault)

    # revert if strategy.token != token
    strategy._setToken_(ZERO_ADDRESS)
    with brownie.reverts("strategy token != ETH"):
        vault.approveStrategy(strategy, {"from": timeLock})

    strategy._setToken_(ETH)

    tx = vault.approveStrategy(strategy, {"from": timeLock})
    strat = vault.strategies(strategy)

    assert strat["approved"]
    assert not strat["active"]
    assert strat["debtRatio"] == 0
    assert strat["debt"] == 0

    assert tx.events["ApproveStrategy"].values() == [strategy]

    # revert if approved
    with brownie.reverts("approved"):
        vault.approveStrategy(strategy, {"from": timeLock})
