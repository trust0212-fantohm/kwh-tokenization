// scripts/upgrade-box.js
import { ethers, upgrades } from "hardhat";

async function main() {
    const MaisonEnergyToken = await ethers.getContractFactory("MaisonEnergyToken");
    const maisonEnergyToken = await upgrades.upgradeProxy("", MaisonEnergyToken);
    console.log("MaisonEnergyToken upgraded");
}

main();