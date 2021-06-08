import pytest
from brownie import (
    accounts,
    Vault,
    UnagiiToken,
    TimeLock,
    FundManager,
    TestTimeLock,
    TestToken,
    TestStrategy,
    TestFundManager,
)


@pytest.fixture(scope="session")
def admin(accounts):
    yield accounts[0]


@pytest.fixture(scope="session")
def guardian(accounts):
    yield accounts[1]


@pytest.fixture(scope="session")
def keeper(accounts):
    yield accounts[2]


@pytest.fixture(scope="session")
def minter(accounts):
    yield accounts[3]


@pytest.fixture(scope="session")
def worker(accounts):
    yield accounts[4]


@pytest.fixture(scope="session")
def attacker(accounts):
    yield accounts[5]


@pytest.fixture(scope="session")
def user(accounts):
    yield accounts[-1]


@pytest.fixture(scope="module")
def timeLock(TimeLock, admin):
    yield TimeLock.deploy({"from": admin})


@pytest.fixture(scope="module")
def testTimeLock(TestTimeLock, admin):
    yield TestTimeLock.deploy({"from": admin})


@pytest.fixture(scope="module")
def token(TestToken, admin):
    yield TestToken.deploy("test", "TEST", 18, {"from": admin})


@pytest.fixture(scope="module")
def uToken(UnagiiToken, token, admin, minter):
    uToken = UnagiiToken.deploy(token, {"from": admin})
    uToken.setMinter(minter, {"from": admin})
    yield uToken


@pytest.fixture(scope="module")
def vault(Vault, token, uToken, admin, guardian, keeper):
    vault = Vault.deploy(token, uToken, guardian, keeper, {"from": admin})

    uToken.setMinter(vault, {"from": admin})

    vault.setPause(False, {"from": admin})
    vault.setDepositLimit(2 ** 256 - 1, {"from": admin})
    yield vault


@pytest.fixture(scope="module")
def fundManager(FundManager, vault, token, admin, guardian, keeper, worker):
    fundManager = FundManager.deploy(token, guardian, keeper, worker, {"from": admin})
    fundManager.setVault(vault, {"from": admin})
    yield fundManager


@pytest.fixture(scope="module")
def testFundManager(TestFundManager, vault, token, admin):
    yield TestFundManager.deploy(vault, token, {"from": admin})


@pytest.fixture(scope="module")
def strategy(TestStrategy, vault, token, admin):
    yield TestStrategy.deploy(vault, token, {"from": admin})