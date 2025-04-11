import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { MaisonEnergyToken, ERCOTPriceOracle, MockUSDC } from "../typechain-types";

describe("MaisonEnergyToken", function () {
    let maisonEnergyToken: MaisonEnergyToken;
    let ercotPriceOracle: ERCOTPriceOracle;
    let mockUSDC: MockUSDC;
    let owner: SignerWithAddress;
    let issuer: SignerWithAddress;
    let backend: SignerWithAddress;
    let user1: SignerWithAddress;
    let user2: SignerWithAddress;

    const ISSUER_ROLE = ethers.keccak256(ethers.toUtf8Bytes("ISSUER_ROLE"));
    const BACKEND_ROLE = ethers.keccak256(ethers.toUtf8Bytes("BACKEND_ROLE"));

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

    const PhysicalDeliveryDays = {
        Mon: 0,
        Tue: 1,
        Wed: 2,
        Thu: 3,
        Fri: 4,
        Sat: 5,
        Sun: 6
    };

    const FuelType = {
        Solar: 0,
        Wind: 1,
        NaturalGas: 2
    };

    beforeEach(async function () {
        [owner, issuer, backend, user1, user2] = await ethers.getSigners();

        // Deploy MockUSDC
        const MockUSDC = await ethers.getContractFactory("MockUSDC");
        mockUSDC = await MockUSDC.deploy();
        await mockUSDC.waitForDeployment();

        // Deploy ERCOTPriceOracle
        const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
        ercotPriceOracle = await upgrades.deployProxy(ERCOTPriceOracle, [], {
            initializer: "initialize",
        });
        await ercotPriceOracle.waitForDeployment();

        // Deploy MaisonEnergyToken
        const MaisonEnergyToken = await ethers.getContractFactory("MaisonEnergyToken");
        maisonEnergyToken = await upgrades.deployProxy(
            MaisonEnergyToken,
            [await ercotPriceOracle.getAddress(), owner.address, await mockUSDC.getAddress()],
            {
                initializer: "initialize",
            }
        );
        await maisonEnergyToken.waitForDeployment();

        // Grant roles
        await maisonEnergyToken.grantRole(ISSUER_ROLE, issuer.address);
        await maisonEnergyToken.grantRole(BACKEND_ROLE, backend.address);

        // Mint some USDC to issuer and users
        await mockUSDC.mint(issuer.address, ethers.parseUnits("10000000", 6));
        await mockUSDC.mint(user1.address, ethers.parseUnits("1000000", 6));
        await mockUSDC.mint(user2.address, ethers.parseUnits("1000000", 6));

        // Approve MaisonEnergyToken to spend USDC
        await mockUSDC.connect(issuer).approve(await maisonEnergyToken.getAddress(), ethers.MaxUint256);
        await mockUSDC.connect(user1).approve(await maisonEnergyToken.getAddress(), ethers.MaxUint256);
        await mockUSDC.connect(user2).approve(await maisonEnergyToken.getAddress(), ethers.MaxUint256);
    });

    describe("Initialization", function () {
        it("Should set correct initial values", async function () {
            expect(await maisonEnergyToken.priceOracle()).to.equal(await ercotPriceOracle.getAddress());
            expect(await maisonEnergyToken.usdc()).to.equal(await mockUSDC.getAddress());
            expect(await maisonEnergyToken.insuranceAddress()).to.equal(owner.address);
        });

        it("Should have correct roles set", async function () {
            expect(await maisonEnergyToken.hasRole(ISSUER_ROLE, issuer.address)).to.be.true;
            expect(await maisonEnergyToken.hasRole(BACKEND_ROLE, backend.address)).to.be.true;
        });
    });

    describe("Minting", function () {
        it("Should allow issuer to mint tokens", async function () {
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30; // 30 days

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await expect(
                maisonEnergyToken.connect(issuer).mint(
                    amount,
                    embeddedValue,
                    validFrom,
                    validTo,
                    "ERCOT123",
                    {
                        zone: ZoneType.LZ_HOUSTON,
                        physicalDelivery: PhysicalDeliveryType.On_Peak,
                        physicalDeliveryHours: 24,
                        physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                        fuelType: FuelType.NaturalGas
                    }
                )
            ).to.not.be.reverted;

            const tokenId = 0;
            const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
            expect(tokenDetail.issuer).to.equal(issuer.address);
            expect(tokenDetail.totalMintedToken).to.equal(amount);
            expect(tokenDetail.totalSupply).to.equal(amount);
        });

        it("Should not allow non-issuer to mint tokens", async function () {
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await expect(
                maisonEnergyToken.connect(user1).mint(
                    amount,
                    embeddedValue,
                    validFrom,
                    validTo,
                    "ERCOT123",
                    {
                        zone: ZoneType.LZ_HOUSTON,
                        physicalDelivery: PhysicalDeliveryType.On_Peak,
                        physicalDeliveryHours: 24,
                        physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                        fuelType: FuelType.NaturalGas
                    }
                )
            ).to.be.revertedWithCustomError(maisonEnergyToken, "AccessControlUnauthorizedAccount");
        });
    });

    describe("Token Destruction", function () {
        it("Should allow issuer to destroy their own tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;
            const destroyAmount = ethers.parseUnits("500", 18);

            await expect(maisonEnergyToken.connect(issuer).destroy(destroyAmount, tokenId))
                .to.not.be.reverted;

            const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
            expect(tokenDetail.totalSupply).to.equal(amount - destroyAmount);
            expect(tokenDetail.totalDestroyed).to.equal(destroyAmount);
        });
    });

    describe("Token Redemption", function () {
        it("Should allow users to redeem tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;
            const redeemAmount = ethers.parseUnits("500", 18);

            // Transfer tokens to user1
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                tokenId,
                redeemAmount,
                "0x"
            );

            await expect(maisonEnergyToken.connect(user1).redeem(tokenId, redeemAmount))
                .to.not.be.reverted;

            const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
            expect(tokenDetail.totalRedeemed).to.equal(redeemAmount);
            expect(await maisonEnergyToken.redeemedTokensForUser(user1.address)).to.equal(redeemAmount);
        });
    });

    describe("Token Expiration", function () {
        it("Should handle token expiration correctly", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;

            // Fast forward time to just before expiration
            await time.increaseTo(validTo - 86400);

            // Check if upkeep is needed
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.true;
            expect(ethers.AbiCoder.defaultAbiCoder().decode(['uint256'], performData)[0]).to.equal(tokenId);

            // Perform upkeep
            await maisonEnergyToken.performUpkeep(performData);

            const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
            expect(tokenDetail.isExpired).to.be.true;
        });
    });

    describe("Debt Settlement", function () {
        it("Should allow backend to settle debts for expired tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;
            const redeemAmount = ethers.parseUnits("500", 18);

            // Transfer tokens to users
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                tokenId,
                redeemAmount,
                "0x"
            );
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user2.address,
                tokenId,
                redeemAmount,
                "0x"
            );

            // Fast forward time to expiration
            await time.increaseTo(validTo + 86400);

            // Perform upkeep to expire token
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            await maisonEnergyToken.performUpkeep(performData);

            // Calculate settlement amounts
            const settlementAmount = ethers.parseUnits("50", 6); // 50 USDC per token

            // Settle debts
            await expect(
                maisonEnergyToken.connect(backend).settleDebtsForExpiration(
                    tokenId,
                    [user1.address, user2.address],
                    [settlementAmount, settlementAmount]
                )
            ).to.not.be.reverted;
        });
    });

    describe("Metrics", function () {
        it("Should return correct token metrics", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;
            const metrics = await maisonEnergyToken.getTokenMetrics(tokenId);

            expect(metrics.tokenDetail.issuer).to.equal(issuer.address);
            expect(metrics.tokenDetail.totalMintedToken).to.equal(amount);
            expect(metrics.tokenDetail.totalSupply).to.equal(amount);
        });

        it("Should return correct issuer metrics", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const metrics = await maisonEnergyToken.getIssuerMetrics(issuer.address);
            expect(metrics.totalKwhMinted).to.equal(amount);
            expect(metrics.totalActiveTokens).to.equal(amount);
        });
    });

    describe("Manual Settlement", function () {
        it("Should allow issuer to manually settle debts for expired tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;
            const redeemAmount = ethers.parseUnits("500", 18);

            // Transfer tokens to users
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                tokenId,
                redeemAmount,
                "0x"
            );
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user2.address,
                tokenId,
                redeemAmount,
                "0x"
            );

            // Fast forward time to expiration
            await time.increaseTo(validTo + 86400);

            // Perform upkeep to expire token
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            await maisonEnergyToken.performUpkeep(performData);

            // Calculate settlement amounts
            const settlementAmount = ethers.parseUnits("50", 6); // 50 USDC per token

            // Approve USDC for settlement
            await mockUSDC.connect(issuer).approve(await maisonEnergyToken.getAddress(), settlementAmount * 2n);

            // Manual settlement
            await expect(
                maisonEnergyToken.connect(issuer).manualSettle(
                    tokenId,
                    [user1.address, user2.address],
                    [settlementAmount, settlementAmount]
                )
            ).to.not.be.reverted;

            // Verify balances after settlement
            expect(await mockUSDC.balanceOf(user1.address)).to.equal(ethers.parseUnits("1000000", 6) + settlementAmount);
            expect(await mockUSDC.balanceOf(user2.address)).to.equal(ethers.parseUnits("1000000", 6) + settlementAmount);
        });

        it("Should not allow non-issuer to manually settle debts", async function () {
            // First mint a token to have a valid token ID
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;

            // Fast forward time to expiration
            await time.increaseTo(validTo + 86400);

            // Perform upkeep to expire token
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            await maisonEnergyToken.performUpkeep(performData);

            const settlementAmount = ethers.parseUnits("50", 6);

            await expect(
                maisonEnergyToken.connect(user1).manualSettle(
                    tokenId,
                    [user1.address],
                    [settlementAmount]
                )
            ).to.be.revertedWith("You are not an issuer of this token");
        });
    });

    describe("Chainlink Automation", function () {
        it("Should correctly check for tokens needing expiration", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;

            // Fast forward time to just before expiration (1 day before)
            await time.increaseTo(validTo - 86400);

            // Check if upkeep is needed
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.true;
        });

        it("Should not need upkeep when no tokens are expiring", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            // Check if upkeep is needed (should be false as token is not expiring soon)
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            expect(upkeepNeeded).to.be.false;
            expect(performData).to.equal("0x");
        });

        it("Should perform upkeep to expire tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;

            // Fast forward time to just before expiration
            await time.increaseTo(validTo - 86400);

            // Perform upkeep
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            await maisonEnergyToken.performUpkeep(performData);

            // Verify token is expired
            const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
            expect(tokenDetail.isExpired).to.be.true;
        });

        it("Should not perform upkeep for already expired tokens", async function () {
            // First mint some tokens
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const validFrom = (await time.latest()) + 3600;
            const validTo = validFrom + 86400 * 30;

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                validFrom,
                validTo,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            const tokenId = 0;

            // Fast forward time to just before expiration
            await time.increaseTo(validTo - 86400);

            // Perform upkeep first time
            const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
            await maisonEnergyToken.performUpkeep(performData);

            // Try to perform upkeep again
            await expect(maisonEnergyToken.performUpkeep(performData))
                .to.be.revertedWith("Token already expired");
        });
    });

    describe("Representative Metrics", function () {
        it("Should return correct metrics for representative with no tokens", async function () {
            const [
                totalRedeemed,
                totalAllocated,
                tokensExpiringIn1,
                tokensExpiringIn2,
                tokensExpiringIn3,
                tokensExpiringIn4,
                tokensExpiringIn5,
                tokensExpiringIn6,
                tokensExpiringIn12,
                tokensExpiringIn24,
                tokensExpiringIn36
            ] = await maisonEnergyToken.getRepMetrics(user1.address);

            expect(totalRedeemed).to.equal(0);
            expect(totalAllocated).to.equal(0);
            expect(tokensExpiringIn1).to.equal(0);
            expect(tokensExpiringIn2).to.equal(0);
            expect(tokensExpiringIn3).to.equal(0);
            expect(tokensExpiringIn4).to.equal(0);
            expect(tokensExpiringIn5).to.equal(0);
            expect(tokensExpiringIn6).to.equal(0);
            expect(tokensExpiringIn12).to.equal(0);
            expect(tokensExpiringIn24).to.equal(0);
            expect(tokensExpiringIn36).to.equal(0);
        });

        it("Should return correct metrics for representative with tokens in different expiration periods", async function () {
            // Mint tokens with different expiration periods
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const currentTime = await time.latest();

            // Token expiring in 1 month
            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                currentTime + 3600,
                currentTime + 30 * 86400, // 30 days
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            // Token expiring in 3 months
            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                currentTime + 3600,
                currentTime + 90 * 86400, // 90 days
                "ERCOT124",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            // Token expiring in 12 months
            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                currentTime + 3600,
                currentTime + 365 * 86400, // 365 days
                "ERCOT125",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            // Transfer tokens to user1
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                0, // First token (1 month)
                amount,
                "0x"
            );

            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                1, // Second token (3 months)
                amount,
                "0x"
            );

            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                2, // Third token (12 months)
                amount,
                "0x"
            );

            // Fast forward time to after tokens become valid but before they expire
            await time.increaseTo(currentTime + 3600 + 1);

            const [
                totalRedeemed,
                totalAllocated,
                tokensExpiringIn1,
                tokensExpiringIn2,
                tokensExpiringIn3,
                tokensExpiringIn4,
                tokensExpiringIn5,
                tokensExpiringIn6,
                tokensExpiringIn12,
                tokensExpiringIn24,
                tokensExpiringIn36
            ] = await maisonEnergyToken.getRepMetrics(user1.address);

            expect(totalRedeemed).to.equal(0);
            expect(totalAllocated).to.equal(amount * 3n);
            expect(tokensExpiringIn1).to.equal(amount);
            expect(tokensExpiringIn2).to.equal(0);
            expect(tokensExpiringIn3).to.equal(amount);
            expect(tokensExpiringIn4).to.equal(0);
            expect(tokensExpiringIn5).to.equal(0);
            expect(tokensExpiringIn6).to.equal(0);
            expect(tokensExpiringIn12).to.equal(amount);
            expect(tokensExpiringIn24).to.equal(0);
            expect(tokensExpiringIn36).to.equal(0);
        });

        it("Should return correct metrics after token redemption", async function () {
            // Mint a token
            const amount = ethers.parseUnits("1000", 18);
            const embeddedValue = ethers.parseUnits("50", 18);
            const currentTime = await time.latest();

            await ercotPriceOracle.updatePrice(
                ZoneType.LZ_HOUSTON,
                PhysicalDeliveryType.On_Peak,
                ethers.parseUnits("100", 18)
            );

            await maisonEnergyToken.connect(issuer).mint(
                amount,
                embeddedValue,
                currentTime + 3600,
                currentTime + 30 * 86400,
                "ERCOT123",
                {
                    zone: ZoneType.LZ_HOUSTON,
                    physicalDelivery: PhysicalDeliveryType.On_Peak,
                    physicalDeliveryHours: 24,
                    physicalDeliveryDays: PhysicalDeliveryDays.Mon,
                    fuelType: FuelType.NaturalGas
                }
            );

            // Transfer token to user1
            await maisonEnergyToken.connect(issuer).safeTransferFrom(
                issuer.address,
                user1.address,
                0,
                amount,
                "0x"
            );

            // Fast forward time to after token becomes valid but before it expires
            await time.increaseTo(currentTime + 3600 + 1);

            // Redeem half of the tokens
            const redeemAmount = amount / 2n;
            await maisonEnergyToken.connect(user1).redeem(0, redeemAmount);

            const [
                totalRedeemed,
                totalAllocated,
                tokensExpiringIn1,
                tokensExpiringIn2,
                tokensExpiringIn3,
                tokensExpiringIn4,
                tokensExpiringIn5,
                tokensExpiringIn6,
                tokensExpiringIn12,
                tokensExpiringIn24,
                tokensExpiringIn36
            ] = await maisonEnergyToken.getRepMetrics(user1.address);

            expect(totalRedeemed).to.equal(redeemAmount);
            expect(totalAllocated).to.equal(amount - redeemAmount);
            expect(tokensExpiringIn1).to.equal(amount - redeemAmount);
            expect(tokensExpiringIn2).to.equal(0);
            expect(tokensExpiringIn3).to.equal(0);
            expect(tokensExpiringIn4).to.equal(0);
            expect(tokensExpiringIn5).to.equal(0);
            expect(tokensExpiringIn6).to.equal(0);
            expect(tokensExpiringIn12).to.equal(0);
            expect(tokensExpiringIn24).to.equal(0);
            expect(tokensExpiringIn36).to.equal(0);
        });
    });
}); 