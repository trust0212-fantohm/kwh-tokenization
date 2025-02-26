import { ethers, upgrades } from "hardhat";
import { insuranceAddress, usdcAddress } from "./address";

async function main() {
    console.log("Deploying Token contract...");

    const MaisonEnergyToken = await ethers.getContractFactory("MaisonEnergyToken")
    const maisonEnergyToken = await upgrades.deployProxy(MaisonEnergyToken, ["", insuranceAddress, usdcAddress], {
        initializer: "initialize",
    });
    await maisonEnergyToken.waitForDeployment();

    console.log(`✅ maisonEnergyToken deployed at: ${await maisonEnergyToken.getAddress()}`);
}

// Execute deployment
main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("Deployment failed:", error);
        process.exit(1);
    });
