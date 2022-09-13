// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.6.10 <0.8.0;

interface IAnyCallV6Proxy {
    function executor() external view returns (address);

    function anyCall(
        address to,
        bytes calldata data,
        address fallbackAddress,
        uint256 toChainID,
        uint256 flags
    ) external payable;
}

interface IAnyCallExecutor {
    function context()
        external
        returns (
            address from,
            uint256 fromChainID,
            uint256 nonce
        );
}

abstract contract AnyCallAppBase {
    uint256 private constant ANY_CALL_FLAG_PAY_ON_DEST = 0;
    uint256 private constant ANY_CALL_FLAG_PAY_ON_SRC = 2;

    address public immutable anyCallProxy;
    uint256 public immutable anyCallFlag;
    bool public immutable anyCallExecuteFallback;

    constructor(
        address anyCallProxy_,
        bool anyCallPayOnSrc_,
        bool anyCallExecuteFallback_
    ) internal {
        anyCallProxy = anyCallProxy_;
        anyCallFlag = anyCallPayOnSrc_ ? ANY_CALL_FLAG_PAY_ON_SRC : ANY_CALL_FLAG_PAY_ON_DEST;
        anyCallExecuteFallback = anyCallExecuteFallback_;
    }

    modifier onlyExecutor() {
        require(msg.sender == IAnyCallV6Proxy(anyCallProxy).executor());
        _;
    }

    function _anyCall(
        address to,
        bytes memory data,
        uint256 toChainID
    ) internal {
        uint256 callValue = anyCallFlag == ANY_CALL_FLAG_PAY_ON_DEST ? 0 : msg.value;
        address fallbackAddress = anyCallExecuteFallback ? address(this) : address(0);
        IAnyCallV6Proxy(anyCallProxy).anyCall{value: callValue}(
            to,
            data,
            fallbackAddress,
            toChainID,
            anyCallFlag
        );
    }

    function anyExecute(bytes calldata data)
        external
        onlyExecutor
        returns (bool success, bytes memory result)
    {
        (address from, uint256 fromChainID, ) =
            IAnyCallExecutor(IAnyCallV6Proxy(anyCallProxy).executor()).context();
        require(
            _checkAnyExecuteFrom(from, fromChainID) && from != address(0),
            "Invalid anyExecute from"
        );
        _anyExecute(fromChainID, data);
        return (true, "");
    }

    function anyFallback(address to, bytes calldata data) external onlyExecutor {
        _anyFallback(to, data);
    }

    function _checkAnyExecuteFrom(address from, uint256 fromChainID)
        internal
        virtual
        returns (bool);

    function _anyExecute(uint256 fromChainID, bytes calldata data) internal virtual;

    function _anyFallback(address to, bytes calldata data) internal virtual;
}
