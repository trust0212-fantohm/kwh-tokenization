import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { ERCOTPriceOracle } from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("ERCOTPriceOracle", function () {
    let ercotPriceOracle: ERCOTPriceOracle;
    let owner: SignerWithAddress;
    let writer: SignerWithAddress;
    let unauthorizedUser: SignerWithAddress;

    // Enum values
    const ZoneType = {
        LZ_NORTH: 0,
        LZ_WEST: 1,
        LZ_SOUTH: 2,
        LZ_HOUSTON: 3
    };

    const PhysicalDeliveryType = {
        On_Peak: 0,
        Off_Peak: 1,
        All: 2
    };

    beforeEach(async function () {
        [owner, writer, unauthorizedUser] = await ethers.getSigners();

        // Deploy ERCOTPriceOracle
        const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
        ercotPriceOracle = await upgrades.deployProxy(ERCOTPriceOracle, [], {
            initializer: "initialize",
        });
        await ercotPriceOracle.waitForDeployment();

        // Grant WRITER_ROLE to writer
        await ercotPriceOracle.grantRole(await ercotPriceOracle.WRITER_ROLE(), writer.address);
    });

    describe("Initialization", function () {
        it("Should set the correct initial roles", async function () {
            expect(await ercotPriceOracle.hasRole(await ercotPriceOracle.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.true;
            expect(await ercotPriceOracle.hasRole(await ercotPriceOracle.WRITER_ROLE(), owner.address)).to.be.true;
            expect(await ercotPriceOracle.hasRole(await ercotPriceOracle.WRITER_ROLE(), writer.address)).to.be.true;
        });
    });

    describe("Price Updates", function () {
        it("Should allow writer to update price", async function () {
            const price = ethers.parseUnits("100", 18);
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            const tx = await ercotPriceOracle.connect(writer).updatePrice(
                zone,
                physicalDelivery,
                price
            );
            const receipt = await tx.wait();
            if (!receipt) throw new Error("Transaction receipt not found");
            const block = await ethers.provider.getBlock(receipt.blockNumber);
            if (!block) throw new Error("Block not found");

            // Verify the price was updated
            const [storedPrice, timestamp] = await ercotPriceOracle.historicalPrice(zone, physicalDelivery, block.timestamp);
            expect(storedPrice).to.equal(price);

            // Verify latest timestamp was updated
            expect(await ercotPriceOracle.getLatestTimestamp(zone, physicalDelivery)).to.equal(block.timestamp);
        });

        it("Should emit PriceUpdated event when price is updated", async function () {
            const price = ethers.parseUnits("100", 18);
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            const tx = await ercotPriceOracle.connect(writer).updatePrice(
                zone,
                physicalDelivery,
                price
            );
            const receipt = await tx.wait();
            if (!receipt) throw new Error("Transaction receipt not found");
            const block = await ethers.provider.getBlock(receipt.blockNumber);
            if (!block) throw new Error("Block not found");

            await expect(tx)
                .to.emit(ercotPriceOracle, "PriceUpdated")
                .withArgs(zone, physicalDelivery, price, block.timestamp);
        });

        it("Should not allow unauthorized user to update price", async function () {
            const price = ethers.parseUnits("100", 18);
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            await expect(ercotPriceOracle.connect(unauthorizedUser).updatePrice(
                zone,
                physicalDelivery,
                price
            )).to.be.revertedWithCustomError(ercotPriceOracle, "AccessControlUnauthorizedAccount");
        });

        it("Should not allow zero price updates", async function () {
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            await expect(ercotPriceOracle.connect(writer).updatePrice(
                zone,
                physicalDelivery,
                0
            )).to.be.revertedWithCustomError(ercotPriceOracle, "ZeroPriceNotAllowed");
        });
    });

    describe("Price Queries", function () {
        let priceTimestamp: number;

        beforeEach(async function () {
            // Set up initial price
            const price = ethers.parseUnits("100", 18);
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            const tx = await ercotPriceOracle.connect(writer).updatePrice(
                zone,
                physicalDelivery,
                price
            );
            const receipt = await tx.wait();
            if (!receipt) throw new Error("Transaction receipt not found");
            const block = await ethers.provider.getBlock(receipt.blockNumber);
            if (!block) throw new Error("Block not found");
            priceTimestamp = block.timestamp;
        });

        it("Should return correct real-time price", async function () {
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;
            const expectedPrice = ethers.parseUnits("100", 18);

            const [price, timestamp] = await ercotPriceOracle.getRealTimePrice(zone, physicalDelivery);
            expect(price).to.equal(expectedPrice);
            expect(timestamp).to.equal(priceTimestamp);
        });

        it("Should return zero for real-time price when no price exists", async function () {
            const zone = ZoneType.LZ_WEST; // Zone with no price set
            const physicalDelivery = PhysicalDeliveryType.On_Peak;

            const [price, timestamp] = await ercotPriceOracle.getRealTimePrice(zone, physicalDelivery);
            expect(price).to.equal(0);
            expect(timestamp).to.equal(0);
        });

        it("Should return correct historical price", async function () {
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;
            const expectedPrice = ethers.parseUnits("100", 18);

            const [price, returnedTimestamp] = await ercotPriceOracle.historicalPrice(
                zone,
                physicalDelivery,
                priceTimestamp
            );
            expect(price).to.equal(expectedPrice);
            expect(returnedTimestamp).to.equal(priceTimestamp);
        });

        it("Should return zero for non-existent historical price", async function () {
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;
            const futureTimestamp = priceTimestamp + 1000;

            const [price, returnedTimestamp] = await ercotPriceOracle.historicalPrice(
                zone,
                physicalDelivery,
                futureTimestamp
            );
            expect(price).to.equal(0);
            expect(returnedTimestamp).to.equal(futureTimestamp);
        });

        it("Should correctly track latest timestamp", async function () {
            const zone = ZoneType.LZ_HOUSTON;
            const physicalDelivery = PhysicalDeliveryType.On_Peak;
            
            // Update price multiple times
            for (let i = 0; i < 3; i++) {
                const price = ethers.parseUnits((100 + i).toString(), 18);
                const tx = await ercotPriceOracle.connect(writer).updatePrice(zone, physicalDelivery, price);
                const receipt = await tx.wait();
                if (!receipt) throw new Error("Transaction receipt not found");
                const block = await ethers.provider.getBlock(receipt.blockNumber);
                if (!block) throw new Error("Block not found");
                
                // Verify latest timestamp is updated
                expect(await ercotPriceOracle.getLatestTimestamp(zone, physicalDelivery)).to.equal(block.timestamp);
                
                // Verify getRealTimePrice returns the latest price
                const [latestPrice, latestTimestamp] = await ercotPriceOracle.getRealTimePrice(zone, physicalDelivery);
                expect(latestPrice).to.equal(price);
                expect(latestTimestamp).to.equal(block.timestamp);
                
                await time.increase(1); // Increase time by 1 second
            }
        });
    });

    describe("Multiple Zones and Delivery Types", function () {
        it("Should handle different zones and delivery types independently", async function () {
            const prices = {
                [ZoneType.LZ_HOUSTON]: {
                    [PhysicalDeliveryType.On_Peak]: ethers.parseUnits("100", 18),
                    [PhysicalDeliveryType.Off_Peak]: ethers.parseUnits("80", 18)
                },
                [ZoneType.LZ_NORTH]: {
                    [PhysicalDeliveryType.On_Peak]: ethers.parseUnits("90", 18),
                    [PhysicalDeliveryType.Off_Peak]: ethers.parseUnits("70", 18)
                }
            };

            const timestamps: { [key: number]: { [key: number]: number } } = {
                [ZoneType.LZ_HOUSTON]: {},
                [ZoneType.LZ_NORTH]: {}
            };

            // Update prices for different combinations
            for (const zone of [ZoneType.LZ_HOUSTON, ZoneType.LZ_NORTH]) {
                for (const delivery of [PhysicalDeliveryType.On_Peak, PhysicalDeliveryType.Off_Peak]) {
                    const tx = await ercotPriceOracle.connect(writer).updatePrice(
                        zone,
                        delivery,
                        prices[zone][delivery]
                    );
                    const receipt = await tx.wait();
                    if (!receipt) throw new Error("Transaction receipt not found");
                    const block = await ethers.provider.getBlock(receipt.blockNumber);
                    if (!block) throw new Error("Block not found");
                    timestamps[zone][delivery] = block.timestamp;

                    // Verify latest timestamp is updated
                    expect(await ercotPriceOracle.getLatestTimestamp(zone, delivery)).to.equal(block.timestamp);

                    // Verify getRealTimePrice returns the correct price
                    const [realTimePrice, realTimeTimestamp] = await ercotPriceOracle.getRealTimePrice(zone, delivery);
                    expect(realTimePrice).to.equal(prices[zone][delivery]);
                    expect(realTimeTimestamp).to.equal(block.timestamp);

                    await time.increase(1); // Increase time by 1 second
                }
            }

            // Verify all historical prices are stored correctly
            for (const zone of [ZoneType.LZ_HOUSTON, ZoneType.LZ_NORTH]) {
                for (const delivery of [PhysicalDeliveryType.On_Peak, PhysicalDeliveryType.Off_Peak]) {
                    const [price, timestamp] = await ercotPriceOracle.historicalPrice(zone, delivery, timestamps[zone][delivery]);
                    expect(price).to.equal(prices[zone][delivery]);
                }
            }
        });
    });
});
