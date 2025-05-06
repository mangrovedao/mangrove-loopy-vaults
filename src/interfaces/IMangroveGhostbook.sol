// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IMangroveGhostbook {
    type Tick is int256;

    struct ModuleData {
        address module;
        bytes data;
    }

    struct OLKey {
        address outbound_tkn;
        address inbound_tkn;
        uint256 tickSpacing;
    }

    function marketOrderByTick(
        OLKey memory olKey,
        Tick maxTick,
        uint256 amountToSell,
        ModuleData memory moduleData
    )
        external
        returns (uint256 takerGot, uint256 takerGave, uint256 bounty, uint256 feePaid);
}
