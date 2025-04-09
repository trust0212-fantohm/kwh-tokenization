// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "../library/CommonTypes.sol";

interface IMaisonEnergyToken {

    event TokenMinted(
        address indexed issuer,
        uint256 indexed id,
        uint256 amount
    );
    event Redeemed(
        address indexed rep,
        uint256 indexed id,
        uint256 amount,
        uint256 physicalDeliveryDate
    );
    event TokenDestroyed(
        address indexed issuer,
        uint256 indexed id,
        uint256 amount
    );
    event TokenExpirationRequested(uint256, uint256);
    event SettlementFailed(
        uint256 indexed tokenId,
        address indexed holder,
        uint256 amount
    );
    event Settled(
        uint256 indexed tokenId,
        address indexed holder,
        uint256 amount
    );
    event SettledAllDebts(
        uint256 indexed tokenId
    );
    event TokenIssuerMarkedAsDefault(
        uint256 indexed tokenId
    );
}
