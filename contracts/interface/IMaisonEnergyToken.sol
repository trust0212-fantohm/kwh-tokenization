// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;
import "../library/CommonTypes.sol";

interface IMaisonEnergyToken {
    struct EnergyAttributes {
        CommonTypes.ZoneType zone;
        CommonTypes.PhysicalDeliveryType physicalDelivery;
        uint256 physicalDeliveryHours;
        CommonTypes.PhysicalDeliveryDays physicalDeliveryDays;
        CommonTypes.FuelType fuelType;
    }

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

    function mint(
        uint256 amount,
        uint256 embeddedValue,
        uint256 validFrom,
        uint256 validTo,
        string memory ercotSupplyId,
        EnergyAttributes memory energyAttributes
    ) external;
    function redeem(uint256 id, uint256 amount) external;
    function destroy(uint256 amount, uint256 id) external;
}
