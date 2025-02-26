// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

library CommonTypes {
    enum PhysicalDeliveryDays {
        Mon,
        Tue,
        Wed,
        Thu,
        Fri,
        Sat,
        Sun
    }
    enum PhysicalDeliveryType {
        On_Peak,
        Off_Peak,
        All
    }
    enum ZoneType {
        LZ_NORTH,
        LZ_WEST,
        LZ_SOUTH,
        LZ_HOUSTON
    }
    enum FuelType {
        Solar,
        Wind,
        NaturalGas
    }
}
