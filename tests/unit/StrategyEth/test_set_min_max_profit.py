import brownie


def test_set_min_max_profit(strategyEthTest, admin, user):
    strategy = strategyEthTest

    # not auth
    with brownie.reverts("!auth"):
        strategy.setMinMaxProfit(0, 1, {"from": user})

    strategy.setMinMaxProfit(1, 2, {"from": admin})

    assert strategy.minProfit() == 1
    assert strategy.maxProfit() == 2
