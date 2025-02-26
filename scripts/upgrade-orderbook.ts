// scripts/upgrade-box.js
import { ethers, upgrades } from "hardhat";

async function main() {
    const MaisonEnergyOrderBook = await ethers.getContractFactory("MaisonEnergyOrderBook");
    const maisonEnergyOrderBook = await upgrades.upgradeProxy("", MaisonEnergyOrderBook);
    console.log("MaisonEnergyOrderBook upgraded");
}

main();