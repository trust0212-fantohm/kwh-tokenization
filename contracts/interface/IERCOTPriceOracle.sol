// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "../library/CommonTypes.sol";

/**
 * @title IERCOTPriceOracle
 * @dev Interface for the ERCOTPriceOracle contract, providing functions to fetch real-time
 *      and historical electricity prices for different ERCOT zones.
 */

interface IERCOTPriceOracle {
    /**
     * @notice Fetches the latest price for a given ERCOT zone.
     * @param zone The ERCOT zone to get the real-time price for.
     * @return The latest recorded price for the specified zone.
     */
    function getRealTimePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) external view returns (uint256, uint256);

    /**
     * @notice Fetches the historical price of a given zone at a specific timestamp.
     * @param zone The ERCOT zone to get the historical price for.
     * @param timestamp The specific timestamp to retrieve the price for.
     * @return The price recorded at the given timestamp and the timestamp itself.
     */
    function historicalPrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        uint256 timestamp
    ) external view returns (uint256, uint256);

    /**
     * @notice Updates the electricity price for a specific ERCOT zone at a given timestamp.
     * @param zone The ERCOT zone where the price is being updated.
     * @param price The new price to be recorded for the given zone and timestamp.
     */
    function updatePrice(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery,
        uint256 price
    ) external;

    /**
     * @notice Gets the latest timestamp for which a price was recorded.
     * @param zone The ERCOT zone to query.
     * @param physicalDelivery The physical delivery type to query.
     * @return The latest timestamp for which a price exists.
     */
    function getLatestTimestamp(
        CommonTypes.ZoneType zone,
        CommonTypes.PhysicalDeliveryType physicalDelivery
    ) external view returns (uint256);

    // Event emitted whenever a price is updated
    event PriceUpdated(
        CommonTypes.ZoneType indexed zone,
        CommonTypes.PhysicalDeliveryType indexed physicalDelivery,
        uint256 price,
        uint256 timestamp
    );
}
