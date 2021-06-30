import brownie
from brownie import StrategyConvexAlUsdDai
import pytest


def test_report(daiFundManager, admin, treasury, dai, dai_whale):
    token = dai
    whale = dai_whale

    fundManager = daiFundManager
    timeLock = fundManager.timeLock()

    strategy = StrategyConvexAlUsdDai.deploy(fundManager, treasury, {"from": admin})

    fundManager.approveStrategy(strategy, {"from": timeLock})
    fundManager.addStrategyToQueue(strategy, 1, 0, 2 ** 256 - 1, {"from": admin})

    amount = 10 ** 18
    token.transfer(fundManager, amount, {"from": whale})

    strategy.deposit(2 ** 256 - 1, 1, {"from": admin})

    def snapshot():
        return {
            "token": {
                "strategy": token.balanceOf(strategy),
                "fundManager": token.balanceOf(fundManager),
            },
            "strategy": {"totalAssets": strategy.totalAssets()},
            "fundManager": {"debt": fundManager.getDebt(strategy)},
        }

    # create profit
    min_profit = 10 ** 18
    token.transfer(strategy, min_profit, {"from": whale})

    before = snapshot()
    tx = strategy.report(0, 2 ** 256 - 1, {"from": admin})
    after = snapshot()

    # print(before)
    # print(after)
    # for e in tx.events:
    #     print(e)

    event = tx.events[-1]
    gain = event["gain"]
    loss = event["loss"]
    free = event["free"]
    total = event["total"]
    debt = event["debt"]

    print(gain, loss, free, total, debt)

    assert gain >= min_profit
    assert loss == 0
    assert free >= min_profit
    assert after["strategy"]["totalAssets"] <= before["strategy"]["totalAssets"] + gain
    assert after["fundManager"]["debt"] == before["fundManager"]["debt"]
    assert after["token"]["fundManager"] == before["token"]["fundManager"] + gain