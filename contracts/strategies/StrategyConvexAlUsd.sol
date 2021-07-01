// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

// TODO: uniswap v3?
import "../interfaces/uniswap/UniswapV2Router.sol";
import "../interfaces/convex/BaseRewardPool.sol";
import "../interfaces/convex/Booster.sol";
import "../interfaces/curve/DepositZapAlUsd3Crv.sol";
import "../interfaces/curve/StableSwapAlUsd3Crv.sol";
import "../interfaces/curve/StableSwap3Crv.sol";
import "../Strategy.sol";

contract StrategyConvexAlUsd is Strategy {
    using SafeERC20 for IERC20;
    using SafeMath for uint;

    // Uniswap and Sushiswap //
    // UNISWAP = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    // SUSHISWAP = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address of DEX (uniswap or sushiswap) to use for selling reward tokens
    // CRV, CVX, ALCX
    address[3] public dex;

    address private constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address private constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address private constant ALCX = 0xdBdb4d16EdA451D0503b854CF79D55697F90c8DF;

    // Solc 0.7 cannot create constant arrays
    address[3] private REWARDS = [CRV, CVX, ALCX];

    // Convex //
    Booster private constant BOOSTER =
        Booster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    // pool id
    uint private constant PID = 36;
    BaseRewardPool private constant REWARD =
        BaseRewardPool(0x02E2151D4F351881017ABdF2DD2b51150841d5B3);
    bool public shouldClaimRewards = true;
    bool public shouldClaimExtras = true;

    // Curve //
    // DepositZap AlUsd + 3Pool
    DepositZapAlUsd3Crv private constant ZAP =
        DepositZapAlUsd3Crv(0xA79828DF1850E8a3A3064576f380D90aECDD3359);
    // StableSwap AlUsd + 3CRV (meta pool)
    StableSwapAlUsd3Crv private constant META_POOL =
        StableSwapAlUsd3Crv(0x43b4FdFD4Ff969587185cDB6f0BD875c5Fc83f8c);
    // StableSwap 3CRV (base pool)
    // StableSwap3Crv private constant BASE_POOL =
    //     StableSwap3Crv(0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7);

    // prevent slippage from deposit / withdraw
    uint public slip = 100;
    uint private constant SLIP_MAX = 10000;

    /*
    0 - alUSD
    1 - DAI
    2 - USDC
    3 - USDT
    */
    // multipliers to normalize token decimals to 10 ** 18
    uint[4] private MULS = [1, 1, 1e12, 1e12];
    uint private immutable MUL; // multiplier of token
    uint private immutable INDEX; // index of token

    // DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F
    // USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
    // USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7

    constructor(
        address _token,
        address _fundManager,
        address _treasury,
        uint _index
    ) Strategy(_token, _fundManager, _treasury) {
        // disable alUsd
        require(_index > 0, "index = 0");
        INDEX = _index;
        MUL = MULS[_index];

        PoolInfo memory poolInfo = BOOSTER.poolInfo(PID);
        require(
            address(META_POOL) == poolInfo.lptoken,
            "curve meta pool != pool info lp"
        );
        require(address(REWARD) == poolInfo.crvRewards, "reward != pool info reward");

        IERC20(_token).safeApprove(address(ZAP), type(uint).max);
        // deposit into BOOSTER
        IERC20(address(META_POOL)).safeApprove(address(BOOSTER), type(uint).max);
        // withdraw from ZAP
        IERC20(address(META_POOL)).safeApprove(address(ZAP), type(uint).max);

        _setDex(0, 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // CRV - sushiswap
        _setDex(1, 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // CVX - sushiswap
        _setDex(2, 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F); // ALCX - sushiswap
    }

    function _setDex(uint _i, address _dex) private {
        IERC20 reward = IERC20(REWARDS[_i]);

        // disallow previous dex
        if (dex[_i] != address(0)) {
            reward.safeApprove(dex[_i], 0);
        }

        dex[_i] = _dex;

        // approve new dex
        reward.safeApprove(_dex, type(uint).max);
    }

    function setDex(uint _i, address _dex) external onlyAuthorized {
        require(_dex != address(0), "dex = 0 address");
        _setDex(_i, _dex);
    }

    /*
    @notice Set max slippage for deposit and withdraw from Curve pool
    @param _slip Max amount of slippage allowed
    */
    function setSlip(uint _slip) external onlyAuthorized {
        require(_slip <= SLIP_MAX, "slip > max");
        slip = _slip;
    }

    // TODO:
    function setShouldClaimRewards(bool _shouldClaimRewards) external onlyAuthorized {
        shouldClaimRewards = _shouldClaimRewards;
    }

    // @dev Claim extra rewards (ALCX) from Convex
    function setShouldClaimExtras(bool _shouldClaimExtras) external onlyAuthorized {
        shouldClaimExtras = _shouldClaimExtras;
    }

    function _totalAssets() private view returns (uint) {
        /*
        s0 = shares in meta pool
        p0 = price per share of meta pool
        s1 = shares in base pool
        p1 = price per share of base pool
        a = amount of tokens (DAI, USDC, USDT)

        s1 = s0 * p0
        a = s1 * p1

        a = s0 * p0 * p1
        */
        // amount of Curve meta pool tokens in Convex
        uint metaBal = REWARD.balanceOf(address(this));
        // amount of alUsd or DAI, USDC, USDT converted from Curve LP
        // BASE_POOL.get_virtual_price is included in META_POOL.get_virtual_price
        // so META_POOL.get_virtual_price = p0 * p1
        uint bal = metaBal.mul(META_POOL.get_virtual_price()) / (MUL * 1e18);

        bal = bal.add(token.balanceOf(address(this)));

        return bal;
    }

    function totalAssets() external view override returns (uint) {
        return _totalAssets();
    }

    function _deposit() private {
        uint bal = token.balanceOf(address(this));
        if (bal > 0) {
            uint[4] memory amounts;
            amounts[INDEX] = bal;
            /*
            shares = token amount * multiplier * 1e18 / price per share
            */
            uint pricePerShare = META_POOL.get_virtual_price();
            uint shares = bal.mul(MUL).mul(1e18).div(pricePerShare);
            uint min = shares.mul(SLIP_MAX - slip) / SLIP_MAX;

            ZAP.add_liquidity(address(META_POOL), amounts, min);
        }

        uint metaBal = META_POOL.balanceOf(address(this));
        if (metaBal > 0) {
            require(BOOSTER.deposit(PID, metaBal, true), "deposit failed");
        }
    }

    function deposit(uint _amount, uint _min) external override onlyAuthorized {
        require(_amount > 0, "deposit = 0");

        uint borrowed = fundManager.borrow(_amount);
        require(borrowed >= _min, "borrowed < min");

        _deposit();
        emit Deposit(_amount, borrowed);
    }

    function _calcSharesToWithdraw(
        uint _amount,
        uint _total,
        uint _totalShares
    ) private pure returns (uint) {
        /*
        calculate shares to withdraw

        a = amount of token to withdraw
        T = total amount of token locked in external liquidity pool
        s = shares to withdraw
        P = total shares deposited into external liquidity pool

        a / T = s / P
        s = a / T * P
        */
        if (_total > 0) {
            // avoid rounding errors and cap shares to be <= total shares
            if (_amount >= _total) {
                return _totalShares;
            }
            return _amount.mul(_totalShares) / _total;
        }
        return 0;
    }

    function _withdraw(uint _amount) private returns (uint) {
        uint bal = token.balanceOf(address(this));
        if (_amount <= bal) {
            return _amount;
        }

        uint total = _totalAssets();

        if (_amount >= total) {
            _amount = total;
        }

        uint need = _amount - bal;
        uint totalShares = REWARD.balanceOf(address(this));
        // total assets is always >= bal
        uint shares = _calcSharesToWithdraw(need, total - bal, totalShares);

        // withdraw from Convex
        // TODO: claim = true?
        if (shares > 0) {
            require(REWARD.withdrawAndUnwrap(shares, false), "reward withdraw failed");
        }

        // withdraw from Curve
        uint metaBal = META_POOL.balanceOf(address(this));
        if (shares > metaBal) {
            shares = metaBal;
        }

        if (shares > 0) {
            uint min = need.mul(SLIP_MAX - slip) / SLIP_MAX;
            ZAP.remove_liquidity_one_coin(
                address(META_POOL),
                shares,
                int128(INDEX),
                min
            );
        }

        uint balAfter = token.balanceOf(address(this));
        if (balAfter < _amount) {
            return balAfter;
        }
        return _amount;
    }

    function withdraw(uint _amount) external override onlyFundManager returns (uint) {
        require(_amount > 0, "withdraw = 0");

        // availabe <= _amount
        uint available = _withdraw(_amount);

        uint loss = 0;
        uint debt = fundManager.getDebt(address(this));
        uint total = _totalAssets();
        if (debt > total) {
            loss = debt - total;
        }

        if (available > 0) {
            token.safeTransfer(msg.sender, available);
        }

        emit Withdraw(_amount, available, loss);

        return loss;
    }

    function repay(uint _amount, uint _min) external override {
        require(_amount > 0, "repay = 0");
        // availabe <= _amount
        uint available = _withdraw(_amount);
        uint repaid = fundManager.repay(available);
        require(repaid >= _min, "repaid < min");

        emit Repay(_amount, repaid);
    }

    /*
    @dev Uniswap fails with zero address so no check is necessary here
    */
    function _swap(
        address _dex,
        address _tokenIn,
        address _tokenOut,
        uint _amount
    ) private {
        // create dynamic array with 3 elements
        address[] memory path = new address[](3);
        path[0] = _tokenIn;
        path[1] = WETH;
        path[2] = _tokenOut;

        UniswapV2Router(_dex).swapExactTokensForTokens(
            _amount,
            1,
            path,
            address(this),
            block.timestamp
        );
    }

    function _claimRewards(uint _minProfit) private {
        // calculate profit = balance of token after - balance of token before
        uint diff = token.balanceOf(address(this));

        require(
            REWARD.getReward(address(this), shouldClaimExtras),
            "get reward failed"
        );

        for (uint i = 0; i < REWARDS.length; i++) {
            uint rewardBal = IERC20(REWARDS[i]).balanceOf(address(this));
            if (rewardBal > 0) {
                _swap(dex[i], REWARDS[i], address(token), rewardBal);
            }
        }

        diff = token.balanceOf(address(this)) - diff;
        require(diff >= _minProfit, "profit < min");

        // transfer performance fee to treasury
        if (diff > 0) {
            uint fee = diff.mul(perfFee) / PERF_FEE_MAX;
            if (fee > 0) {
                token.safeTransfer(treasury, fee);
                diff = diff.sub(fee);
            }
        }

        emit ClaimRewards(diff);
    }

    function claimRewards(uint _minProfit) external override onlyAuthorized {
        _claimRewards(_minProfit);
    }

    function _skim() private {
        uint total = _totalAssets();
        uint debt = fundManager.getDebt(address(this));
        require(total > debt, "total <= debt");

        uint profit = total - debt;
        // reassign to actual amount withdrawn
        profit = _withdraw(profit);

        emit Skim(total, debt, profit);
    }

    function skim() external override onlyAuthorized {
        _skim();
    }

    function _report(uint _minTotal, uint _maxTotal) private {
        uint total = _totalAssets();
        require(total >= _minTotal, "total < min");
        require(total <= _maxTotal, "total > max");

        uint gain = 0;
        uint loss = 0;
        uint free = 0; // balance of token
        uint debt = fundManager.getDebt(address(this));
        if (total > debt) {
            gain = total - debt;

            free = token.balanceOf(address(this));
            if (gain > free) {
                gain = free;
            }
        } else {
            loss = debt - total;
        }

        if (gain > 0 || loss > 0) {
            fundManager.report(gain, loss);
        }

        emit Report(gain, loss, free, total, debt);
    }

    function report(uint _minTotal, uint _maxTotal) external override onlyAuthorized {
        _report(_minTotal, _maxTotal);
    }

    function harvest(
        uint _minProfit,
        uint _minTotal,
        uint _maxTotal
    ) external override onlyAuthorized {
        _claimRewards(_minProfit);
        _skim();
        _report(_minTotal, _maxTotal);
    }

    function migrate(address _strategy) external override onlyFundManager {
        Strategy strat = Strategy(_strategy);
        require(address(strat.token()) == address(token), "strategy token != token");
        require(
            address(strat.fundManager()) == address(fundManager),
            "strategy fund manager != fund manager"
        );
        uint bal = _withdraw(type(uint).max);
        token.safeApprove(_strategy, bal);
        strat.transferFrom(address(this), bal);
    }

    /*
    @notice Transfer token accidentally sent here to admin
    @param _token Address of token to transfer
    */
    function sweep(address _token) external override onlyAuthorized {
        require(_token != address(token), "protected token");
        require(_token != address(CVX), "protected token");
        require(_token != address(ALCX), "protected token");
        require(_token != address(CRV), "protected token");
        IERC20(_token).safeTransfer(admin, IERC20(_token).balanceOf(address(this)));
    }
}
