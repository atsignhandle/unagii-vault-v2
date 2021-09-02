import pytest
from brownie import (
    ZERO_ADDRESS,
    accounts,
    Vault,
    UnagiiToken,
    TimeLock,
    TestToken,
    TestFlash,
    TestZap,
)


ETH = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE"


@pytest.fixture(scope="session")
def admin(accounts):
    yield accounts[0]


@pytest.fixture(scope="session")
def guardian(accounts):
    yield accounts[1]


@pytest.fixture(scope="session")
def worker(accounts):
    yield accounts[2]


@pytest.fixture(scope="session")
def treasury(accounts):
    yield accounts[3]


@pytest.fixture(scope="session")
def attacker(accounts):
    yield accounts[-2]


@pytest.fixture(scope="session")
def user(accounts):
    yield accounts[-1]


@pytest.fixture(scope="session")
def eth_whale(accounts):
    yield accounts[-1]


@pytest.fixture(scope="module")
def timeLock(TimeLock, admin):
    yield TimeLock.deploy({"from": admin})


@pytest.fixture(scope="module")
def token(TestToken, admin):
    yield TestToken.deploy("test", "TEST", 18, {"from": admin})


@pytest.fixture(scope="module")
def uToken(UnagiiToken, token, admin):
    uToken = UnagiiToken.deploy(token, {"from": admin})
    yield uToken


@pytest.fixture(scope="module")
def uEth(UnagiiToken, admin):
    uEth = UnagiiToken.deploy(ETH, {"from": admin})
    yield uEth


@pytest.fixture(scope="module")
def vault(Vault, token, uToken, admin, guardian, worker):
    vault = Vault.deploy(token, uToken, guardian, worker, {"from": admin})
    yield vault


@pytest.fixture(scope="module")
def flash(TestFlash, token, uToken, vault, attacker):
    flash = TestFlash.deploy(token, uToken, vault, {"from": attacker})
    yield flash


@pytest.fixture(scope="module")
def zap(TestZap, token, uToken, vault, admin):
    zap = TestZap.deploy(token, uToken, vault, {"from": admin})
    yield zap


# time lock delay
DELAY = 24 * 3600


@pytest.fixture(scope="module")
def setup(chain, uToken, vault, timeLock, admin):
    # uToken - set minter to vault
    uToken.setMinter(vault, {"from": admin})

    # uToken - set next time lock
    uToken.setNextTimeLock(timeLock, {"from": admin})

    data = uToken.acceptTimeLock.encode_input()
    tx = timeLock.queue(uToken, 0, data, DELAY, 0, {"from": admin})
    eta = tx.timestamp + DELAY
    chain.sleep(DELAY)
    timeLock.execute(uToken, 0, data, eta, 0, {"from": admin})

    # vault - setup
    vault.setBlockDelay(1, {"from": admin})
    vault.setPause(False, {"from": admin})

    # vault - set admin to time lock
    vault.setNextTimeLock(timeLock, {"from": admin})

    data = vault.acceptTimeLock.encode_input()
    tx = timeLock.queue(vault, 0, data, DELAY, 0, {"from": admin})
    eta = tx.timestamp + DELAY
    chain.sleep(DELAY)
    timeLock.execute(vault, 0, data, eta, 0, {"from": admin})
