// scripts/upgrade-box.js
import { ethers, upgrades } from "hardhat";

async function main() {
    const ERCOTPriceOracle = await ethers.getContractFactory("ERCOTPriceOracle");
    const eRCOTPriceOracle = await upgrades.upgradeProxy("", ERCOTPriceOracle);
    console.log("ERCOTPriceOracle upgraded");
}

main();