import brownie
from brownie import interface
import pytest


@pytest.fixture(scope="session")
def zap():
    yield interface.DepositZapAlUsd3Crv("0xA79828DF1850E8a3A3064576f380D90aECDD3359")


@pytest.fixture(scope="session")
def reward():
    yield interface.BaseRewardPool("0x02E2151D4F351881017ABdF2DD2b51150841d5B3")


@pytest.fixture(scope="session")
def alUsd3Crv():
    yield interface.IERC20("0x43b4FdFD4Ff969587185cDB6f0BD875c5Fc83f8c")