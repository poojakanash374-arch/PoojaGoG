const { ethers } = require("hardhat");

async function main() {
  const ProofStakeFinance = await ethers.getContractFactory("ProofStakeFinance");
  const proofStakeFinance = await ProofStakeFinance.deploy();

  await proofStakeFinance.deployed();

  console.log("ProofStakeFinance contract deployed to:", proofStakeFinance.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
