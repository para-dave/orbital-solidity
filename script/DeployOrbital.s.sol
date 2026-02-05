// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/OrbitalPool.sol";
import "../contracts/mocks/MockERC20.sol";

/**
 * @title DeployOrbital
 * @notice Deployment script for Orbital AMM on Tempo testnet
 */
contract DeployOrbital is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying from:", deployer);
        console.log("Deployer balance:", deployer.balance);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy mock tokens (for testnet)
        // In production, use actual stablecoin addresses
        MockERC20 usdc = new MockERC20("USD Coin (Test)", "USDC");
        MockERC20 usdt = new MockERC20("Tether (Test)", "USDT");
        MockERC20 dai = new MockERC20("Dai (Test)", "DAI");

        console.log("Deployed USDC at:", address(usdc));
        console.log("Deployed USDT at:", address(usdt));
        console.log("Deployed DAI at:", address(dai));

        // Mint test tokens to deployer
        usdc.mint(deployer, 1000000 * 10**18);
        usdt.mint(deployer, 1000000 * 10**18);
        dai.mint(deployer, 1000000 * 10**18);

        console.log("Minted 1M test tokens to deployer");

        // Deploy Orbital Pool
        address[] memory tokens = new address[](3);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        tokens[2] = address(dai);

        OrbitalPool pool = new OrbitalPool(tokens);

        console.log("Deployed OrbitalPool at:", address(pool));
        console.log("Pool configuration:");
        console.log("  Number of tokens:", pool.nTokens());
        console.log("  sqrtN:", pool.sqrtN());

        // Create initial tick and add liquidity
        uint256 initialAmount = 10000 * 10**18; // 10,000 of each token

        // Calculate r and k
        uint256 avg = initialAmount;
        uint256 r = (avg * 10**18) / pool.oneMinusOneOverSqrtN();

        uint256 kBase = (r * (pool.sqrtN() - 10**18)) / 10**18;
        uint256 k = (kBase * 11) / 10; // 1.1x

        console.log("Creating initial tick with r:", r);
        uint256 tickId = pool.createTick(r, k);
        console.log("Created tick ID:", tickId);

        // Approve tokens
        usdc.approve(address(pool), initialAmount);
        usdt.approve(address(pool), initialAmount);
        dai.approve(address(pool), initialAmount);

        // Add liquidity
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = initialAmount;
        amounts[1] = initialAmount;
        amounts[2] = initialAmount;

        uint256 shares = pool.addLiquidity(tickId, amounts);
        console.log("Added initial liquidity, received shares:", shares);

        // Verify deployment
        console.log("\nDeployment complete!");
        (uint256[] memory totalReserves,,) = pool.getGlobalState();
        console.log("Pool reserves:");
        console.log("  USDC:", totalReserves[0]);
        console.log("  USDT:", totalReserves[1]);
        console.log("  DAI:", totalReserves[2]);

        console.log("\nInitial price (USDT/USDC):", pool.getPrice(0, 1));

        vm.stopBroadcast();

        // Save deployment addresses
        _saveDeployment(address(pool), address(usdc), address(usdt), address(dai));
    }

    function _saveDeployment(
        address pool,
        address usdc,
        address usdt,
        address dai
    ) internal {
        string memory json = string.concat(
            '{\n',
            '  "pool": "', vm.toString(pool), '",\n',
            '  "usdc": "', vm.toString(usdc), '",\n',
            '  "usdt": "', vm.toString(usdt), '",\n',
            '  "dai": "', vm.toString(dai), '"\n',
            '}'
        );

        vm.writeFile("deployment.json", json);
        console.log("\nDeployment addresses saved to deployment.json");
    }
}
