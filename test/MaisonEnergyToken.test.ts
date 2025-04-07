import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import {
  MaisonEnergyToken,
  MockUSDC,
  ERCOTPriceOracle
} from "../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

interface EnergyAttributes {
  zone: number;
  physicalDelivery: number;
  physicalDeliveryHours: number;
  physicalDeliveryDays: number;
  fuelType: number;
}

describe("MaisonEnergyToken", function () {
  let maisonEnergyToken: MaisonEnergyToken;
  let mockUSDC: MockUSDC;
  let ercotPriceOracle: ERCOTPriceOracle;
  let owner: SignerWithAddress;
  let issuer: SignerWithAddress;
  let user: SignerWithAddress;
  let insuranceAddress: SignerWithAddress;
  const BASE_BIPS = 10000n;

  beforeEach(async function () {
    [owner, issuer, user, insuranceAddress] = await ethers.getSigners();

    // Deploy MockUSDC
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    mockUSDC = await MockUSDC.deploy() as MockUSDC;
    await mockUSDC.waitForDeployment();

    // Deploy ERCOTPriceOracle
    const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
    ercotPriceOracle = await upgrades.deployProxy(
      ERCOTPriceOracle,
      [],
      {
        initializer: "initialize",
      }
    );
    await ercotPriceOracle.waitForDeployment();

    // Deploy MaisonEnergyToken
    const MaisonEnergyToken = await ethers.getContractFactory("MaisonEnergyToken");
    maisonEnergyToken = await upgrades.deployProxy(
      MaisonEnergyToken,
      [
        await ercotPriceOracle.getAddress(),
        await insuranceAddress.getAddress(),
        await mockUSDC.getAddress()
      ],
      {
        initializer: "initialize",
      }
    ) as MaisonEnergyToken;
    await maisonEnergyToken.waitForDeployment();

    console.log("MaisonEnergyToken deployed to:", await maisonEnergyToken.getAddress());
    console.log("MockUSDC deployed to:", await mockUSDC.getAddress());
    console.log("ERCOTPriceOracle deployed to:", await ercotPriceOracle.getAddress());

    // Grant ISSUER_ROLE to issuer
    await maisonEnergyToken.grantRole(
      await maisonEnergyToken.ISSUER_ROLE(),
      await issuer.getAddress()
    );

    // Grant WRITER_ROLE to owner in ERCOTPriceOracle
    await ercotPriceOracle.grantRole(
      await ercotPriceOracle.WRITER_ROLE(),
      await owner.getAddress()
    );

    // Set up initial price in oracle
    await ercotPriceOracle.updatePrice(
      0, // ZoneType
      0, // PhysicalDeliveryType
      ethers.parseUnits("0.1", 6) // $0.1 per kWh
    );
  });

  describe("Initialization", function () {
    it("Should set the correct initial values", async function () {
      expect(await maisonEnergyToken.priceOracle()).to.equal(await ercotPriceOracle.getAddress());
      expect(await maisonEnergyToken.usdc()).to.equal(await mockUSDC.getAddress());
      expect(await maisonEnergyToken.insuranceAddress()).to.equal(await insuranceAddress.getAddress());
    });

    it("Should have correct roles set", async function () {
      expect(await maisonEnergyToken.hasRole(await maisonEnergyToken.ISSUER_ROLE(), await issuer.getAddress())).to.be.true;
      expect(await maisonEnergyToken.hasRole(await maisonEnergyToken.DEFAULT_ADMIN_ROLE(), await owner.getAddress())).to.be.true;
    });
  });

  describe("Token Minting", function () {
    it("Should allow issuer to mint tokens", async function () {
      const amount = ethers.parseUnits("1000", 18); // 1000 kWh
      const embeddedValue = ethers.parseUnits("0.1", 18);
      const currentTime = BigInt(await time.latest());
      const validFrom = currentTime + 3600n; // 1 hour from now
      const validTo = validFrom + 86400n; // 24 hours later

      // Approve USDC for collateral
      const collateralAmount = (amount * embeddedValue) / ethers.parseUnits("1", 18) * 100n / BASE_BIPS; // 1% collateral
      await mockUSDC.approve(await maisonEnergyToken.getAddress(), collateralAmount);

      const energyAttributes: EnergyAttributes = {
        zone: 0,
        physicalDelivery: 0,
        physicalDeliveryHours: 0,
        physicalDeliveryDays: 0,
        fuelType: 0
      };

      await expect(maisonEnergyToken.connect(issuer).mint(
        amount,
        embeddedValue,
        validFrom,
        validTo,
        "ERCOT123",
        energyAttributes
      )).to.emit(maisonEnergyToken, "TokenMinted");
    });

    it("Should not allow minting with invalid timestamps", async function () {
      const amount = ethers.parseUnits("1000", 18);
      const embeddedValue = ethers.parseUnits("0.1", 18);
      const validFrom = BigInt(await time.latest());
      const validTo = validFrom + 86400n;

      const energyAttributes: EnergyAttributes = {
        zone: 0,
        physicalDelivery: 0,
        physicalDeliveryHours: 0,
        physicalDeliveryDays: 0,
        fuelType: 0
      };

      await expect(maisonEnergyToken.connect(issuer).mint(
        amount,
        embeddedValue,
        validFrom,
        validTo,
        "ERCOT123",
        energyAttributes
      )).to.be.revertedWith("Invalid timestamp");
    });
  });

  describe("Token Redemption", function () {
    beforeEach(async function () {
      // Mint tokens first
      const amount = ethers.parseUnits("1000", 18);
      const embeddedValue = ethers.parseUnits("0.1", 18);
      const currentTime = BigInt(await time.latest());
      const validFrom = currentTime + 3600n;
      const validTo = validFrom + 86400n;

      await mockUSDC.approve(await maisonEnergyToken.getAddress(), (amount * embeddedValue) / ethers.parseUnits("1", 18) * 100n / BASE_BIPS);

      const energyAttributes: EnergyAttributes = {
        zone: 0,
        physicalDelivery: 0,
        physicalDeliveryHours: 0,
        physicalDeliveryDays: 0,
        fuelType: 0
      };

      await maisonEnergyToken.connect(issuer).mint(
        amount,
        embeddedValue,
        validFrom,
        validTo,
        "ERCOT123",
        energyAttributes
      );

      // Transfer some tokens to user
      await maisonEnergyToken.connect(issuer).safeTransferFrom(
        await issuer.getAddress(),
        await user.getAddress(),
        0, // tokenId
        amount / 2n,
        "0x"
      );
    });

    it("Should allow user to redeem tokens", async function () {
      const tokenId = 0;
      const amount = ethers.parseUnits("100", 18);

      await expect(maisonEnergyToken.connect(user).redeem(tokenId, amount))
        .to.emit(maisonEnergyToken, "Redeemed");
    });

    it("Should not allow issuer to redeem their own tokens", async function () {
      const tokenId = 0;
      const amount = ethers.parseUnits("100", 18);

      await expect(maisonEnergyToken.connect(issuer).redeem(tokenId, amount))
        .to.be.revertedWith("You are an issuer of this token");
    });
  });

  describe("Token Destruction", function () {
    beforeEach(async function () {
      // Mint tokens first
      const amount = ethers.parseUnits("1000", 18);
      const embeddedValue = ethers.parseUnits("0.1", 18);
      const currentTime = BigInt(await time.latest());
      const validFrom = currentTime + 3600n;
      const validTo = validFrom + 86400n;

      await mockUSDC.approve(await maisonEnergyToken.getAddress(), (amount * embeddedValue) / ethers.parseUnits("1", 18) * 100n / BASE_BIPS);

      const energyAttributes: EnergyAttributes = {
        zone: 0,
        physicalDelivery: 0,
        physicalDeliveryHours: 0,
        physicalDeliveryDays: 0,
        fuelType: 0
      };

      await maisonEnergyToken.connect(issuer).mint(
        amount,
        embeddedValue,
        validFrom,
        validTo,
        "ERCOT123",
        energyAttributes
      );
    });

    it("Should allow issuer to destroy tokens", async function () {
      const tokenId = 0;
      const amount = ethers.parseUnits("100", 18);

      await expect(maisonEnergyToken.connect(issuer).destroy(amount, tokenId))
        .to.emit(maisonEnergyToken, "TokenDestroyed");
    });
  });

  describe("Token Expiration", function () {
    beforeEach(async function () {
      // Mint tokens first
      const amount = ethers.parseUnits("1000", 18);
      const embeddedValue = ethers.parseUnits("0.1", 18);
      const currentTime = BigInt(await time.latest());
      const validFrom = currentTime + 3600n;
      const validTo = validFrom + 86400n;

      await mockUSDC.approve(await maisonEnergyToken.getAddress(), (amount * embeddedValue) / ethers.parseUnits("1", 18) * 100n / BASE_BIPS);

      const energyAttributes: EnergyAttributes = {
        zone: 0,
        physicalDelivery: 0,
        physicalDeliveryHours: 0,
        physicalDeliveryDays: 0,
        fuelType: 0
      };

      await maisonEnergyToken.connect(issuer).mint(
        amount,
        embeddedValue,
        validFrom,
        validTo,
        "ERCOT123",
        energyAttributes
      );
    });

    it("Should mark token as expired when validTo is reached", async function () {
      const tokenId = 0;
      const tokenDetail = await maisonEnergyToken.tokenDetails(tokenId);

      // Fast forward time to expiration
      await time.increaseTo(tokenDetail.validTo);

      // Perform upkeep check
      const [upkeepNeeded, performData] = await maisonEnergyToken.checkUpkeep("0x");
      expect(upkeepNeeded).to.be.true;

      // Perform upkeep
      await maisonEnergyToken.performUpkeep(performData);

      // Verify token is marked as expired
      const updatedTokenDetail = await maisonEnergyToken.tokenDetails(tokenId);
      expect(updatedTokenDetail.isExpired).to.be.true;
    });
  });
}); 