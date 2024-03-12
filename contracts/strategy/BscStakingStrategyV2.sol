// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.6.10 <0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../utils/SafeDecimalMath.sol";

import "../interfaces/IFundV3.sol";
import "../interfaces/IFundForStrategy.sol";
import "../interfaces/IWrappedERC20.sol";

interface IStakeHub {
    function unbondPeriod() external view returns (uint256);

    function getValidators(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory operatorAddrs, address[] memory creditAddrs, uint256 totalLength);

    function delegate(address operatorAddress, bool delegateVotePower) external payable;

    function undelegate(address operatorAddress, uint256 shares) external;

    function redelegate(
        address srcValidator,
        address dstValidator,
        uint256 shares,
        bool delegateVotePower
    ) external;

    function claim(address operatorAddresses, uint256 requestNumbers) external;
}

interface IStakeCredit is IERC20 {
    struct UnbondRequest {
        uint256 shares;
        uint256 bnbAmount;
        uint256 unlockTime;
    }

    function claimableUnbondRequest(address delegator) external view returns (uint256);

    function getPooledBNB(address account) external view returns (uint256);

    function getSharesByPooledBNB(uint256 bnbAmount) external view returns (uint256);

    function lockedBNBs(address delegator, uint256 number) external view returns (uint256);

    function unbondSequence(address delegator) external view returns (uint256);

    function unbondRequest(
        address delegator,
        uint256 _index
    ) external view returns (UnbondRequest memory);
}

contract BscStakingStrategyV2 is Ownable {
    using SafeMath for uint256;
    using SafeDecimalMath for uint256;
    using SafeERC20 for IWrappedERC20;

    event ValidatorsUpdated(uint256[] operatorIndices);
    event Received(address from, uint256 amount);

    IStakeHub public STAKE_HUB;

    address public immutable fund;
    address private immutable _tokenUnderlying;

    address[] public operators;
    IStakeCredit[] public credits;

    /// @notice Amount of underlying lost since the last peak. Performance fee is charged
    ///         only when this value is zero.
    uint256 public currentDrawdown;

    /// @notice The last trading day when a reporter reports daily profit.
    uint256 public reportedDay;

    /// @notice Fraction of profit that goes to the fund's fee collector.
    uint256 public performanceFeeRate;

    constructor(
        address fund_,
        uint256 performanceFeeRate_,
        uint256[] memory operatorIndices
    ) public {
        fund = fund_;
        _tokenUnderlying = IFundV3(fund_).tokenUnderlying();
        performanceFeeRate = performanceFeeRate_;
        updateOperators(operatorIndices);
    }

    function getWithdrawalCapacity()
        external
        view
        returns (uint256 pendingAmount, uint256 withdrawalCapacity)
    {
        for (uint256 i = 0; i < operators.length; i++) {
            pendingAmount = pendingAmount.add(credits[i].lockedBNBs(address(this), 0));
            // Skip if there is an ongoing request
            uint256 unbondSequence = credits[i].unbondSequence(address(this));
            if (
                block.timestamp < credits[i].unbondRequest(address(this), unbondSequence).unlockTime
            ) {
                continue;
            }
            uint256 stakes = credits[i].getPooledBNB(address(this));
            withdrawalCapacity = withdrawalCapacity.add(stakes);
        }
    }

    function deposit(uint256 amount) external onlyPrimaryMarket {
        require(credits.length > 0, "No stake credit");
        // Find the operator with least deposits
        uint256 minStake = type(uint256).max;
        address nextOperator = address(0);
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 temp = credits[i].getPooledBNB(address(this));
            if (temp < minStake) {
                minStake = temp;
                nextOperator = operators[i];
            }
        }
        // Deposit to the operator
        IFundForStrategy(fund).transferToStrategy(amount);
        _unwrap(amount);
        STAKE_HUB.delegate{value: amount}(nextOperator, true);
    }

    function withdraw(uint256 amount) external onlyPrimaryMarket {
        for (uint256 i = 0; i < operators.length; i++) {
            // Skip if there are at least one ongoing request
            uint256 unbondSequence = credits[i].unbondSequence(address(this));
            if (
                block.timestamp < credits[i].unbondRequest(address(this), unbondSequence).unlockTime
            ) {
                continue;
            }
            // Undelegate until fulfilling the user's request
            uint256 stakes = credits[i].getPooledBNB(address(this));
            if (stakes >= amount) {
                STAKE_HUB.undelegate(operators[i], credits[i].getSharesByPooledBNB(amount));
                return;
            }
            amount = amount - stakes;
            STAKE_HUB.undelegate(operators[i], credits[i].balanceOf(address(this)));
        }
        revert("Not enough to withdraw");
    }

    function claim() external {
        // Claim all claimable requests
        for (uint256 i = 0; i < operators.length; i++) {
            uint256 requestNumber = credits[i].claimableUnbondRequest(address(this));
            if (requestNumber > 0) {
                STAKE_HUB.claim(operators[i], requestNumber);
            }
        }
        // Wrap to WBNB
        _wrap(address(this).balance);
        uint256 amount = IWrappedERC20(_tokenUnderlying).balanceOf(address(this));
        if (amount > 0) {
            IWrappedERC20(_tokenUnderlying).safeApprove(fund, amount);
            IFundForStrategy(fund).transferFromStrategy(amount);
        }
    }

    function redelegate(
        address srcValidator,
        address dstValidator,
        uint256 shares,
        bool delegateVotePower
    ) external onlyOwner {
        STAKE_HUB.redelegate(srcValidator, dstValidator, shares, delegateVotePower);
    }

    /// @notice Report profit to the fund by the owner.
    function reportProfit(uint256 amount) external onlyOwner {
        reportedDay = IFundV3(fund).currentDay();
        _reportProfit(amount);
    }

    /// @notice Report loss to the fund. Performance fee will not be charged until
    ///         the current drawdown is covered.
    function reportLoss(uint256 amount) external onlyOwner {
        reportedDay = IFundV3(fund).currentDay();
        currentDrawdown = currentDrawdown.add(amount);
        IFundForStrategy(fund).reportLoss(amount);
    }

    /// @dev Report profit and performance fee to the fund. Performance fee is charged only when
    ///      there's no previous loss to cover.
    function _reportProfit(uint256 amount) private {
        uint256 oldDrawdown = currentDrawdown;
        if (amount < oldDrawdown) {
            currentDrawdown = oldDrawdown - amount;
            IFundForStrategy(fund).reportProfit(amount, 0);
        } else {
            if (oldDrawdown > 0) {
                currentDrawdown = 0;
            }
            uint256 performanceFee = (amount - oldDrawdown).multiplyDecimal(performanceFeeRate);
            IFundForStrategy(fund).reportProfit(amount, performanceFee);
        }
    }

    /// @notice Receive cross-chain transfer from the staker.
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    function updateOperators(uint256[] memory operatorIndices) public onlyOwner {
        require(operatorIndices.length > 0);
        delete operators;
        delete credits;
        for (uint256 i = 0; i < operatorIndices.length; i++) {
            (address[] memory operatorAddrs, address[] memory creditAddrs, ) = STAKE_HUB
                .getValidators(operatorIndices[i], 1);
            operators.push(operatorAddrs[0]);
            credits.push(IStakeCredit(creditAddrs[0]));
        }
        emit ValidatorsUpdated(operatorIndices);
    }

    /// @dev Convert BNB into WBNB
    function _wrap(uint256 amount) private {
        IWrappedERC20(_tokenUnderlying).deposit{value: amount}();
    }

    /// @dev Convert WBNB into BNB
    function _unwrap(uint256 amount) private {
        IWrappedERC20(_tokenUnderlying).withdraw(amount);
    }

    modifier onlyPrimaryMarket() {
        require(msg.sender == IFundV3(fund).primaryMarket(), "Only fund can deposit");
        _;
    }
}