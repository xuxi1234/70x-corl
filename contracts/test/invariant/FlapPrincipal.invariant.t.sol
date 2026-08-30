// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter} from "../../src/interfaces/IFlapAdapter.sol";
import {FlapMintVault} from "../../src/vaults/FlapMintVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
}

contract AlwaysFailingFlapAdapter is IFlapAdapter {
    function execute(LaunchRequest calldata) external payable returns (LaunchResult memory) {
        revert("protocol failure");
    }
}

contract FlapPrincipalHandler {
    FlapMintVault public immutable vault;

    constructor(FlapMintVault vault_) {
        vault = vault_;
    }

    function retry(uint64 deadlineSeed, uint256 minimumSeed) external {
        uint256 deadline = block.timestamp + (uint256(deadlineSeed) % 1 days) + 1;
        uint256 minimumPurchased = (minimumSeed % 1_000 ether) + 1;
        vault.retryLaunch(
            IFlapAdapter.LaunchRequest(0, address(0), bytes32(minimumSeed), minimumPurchased, deadline, 0)
        );
    }
}

contract FlapPrincipalInvariantTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    AlwaysFailingFlapAdapter private adapter;
    FlapMintVault private vault;
    FlapPrincipalHandler private handler;
    uint256 private creatorBalance;
    uint256 private adapterBalance;

    function setUp() public {
        adapter = new AlwaysFailingFlapAdapter();
        vault = new FlapMintVault(address(this), address(adapter), 2 ether, 2, bytes32(0), 0, 0);
        VM.deal(address(this), 2 ether);
        vault.mint{value: 2 ether}(2);
        handler = new FlapPrincipalHandler(vault);
        creatorBalance = address(this).balance;
        adapterBalance = address(adapter).balance;
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_failedLaunchNeverLeaksPrincipal() external view {
        require(address(vault).balance == vault.totalPaid(), "vault principal changed");
        require(address(this).balance == creatorBalance, "creator received principal");
        require(address(adapter).balance == adapterBalance, "adapter retained principal");
    }
}
