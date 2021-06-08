import brownie
from brownie import ZERO_ADDRESS
import pytest


def test_queue(timeLock, testTimeLock, admin):
    value = 1
    data = "0x1212"
    delay = 24 * 3600
    nonce = 0

    tx = timeLock.queue(testTimeLock, value, data, delay, nonce, {"from": admin})

    eta = tx.timestamp + delay
    txHash = timeLock.getTxHash(testTimeLock, value, data, eta, nonce)

    assert timeLock.queued(txHash)
    assert len(tx.events) == 1
    assert tx.events["Log"].values() == [txHash, testTimeLock, 1, data, eta, nonce, 0]


def test_queue_not_admin(timeLock, user):
    with brownie.reverts("!admin"):
        timeLock.queue(ZERO_ADDRESS, 0, "", 0, 0, {"from": user})


def test_queue_min_delay(timeLock, admin):
    with brownie.reverts("delay < min"):
        timeLock.queue(ZERO_ADDRESS, 0, "", 0, 0, {"from": admin})