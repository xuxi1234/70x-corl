// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FinanceVault} from "../../src/vaults/FinanceVault.sol";

interface Vm {
    function deal(address account, uint256 newBalance) external;
}

contract InvariantFinanceToken {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract FinanceCapHandler {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    FinanceVault public immutable vault;
    uint256 public immutable positionId;
    uint256 public totalFunded;

    constructor(FinanceVault vault_) {
        vault = vault_;
        VM.deal(address(this), 10_000 ether);
        positionId = vault.openNative{value: 1 ether}(50_000);
    }

    function fund(uint96 seed) external {
        uint256 amount = uint256(seed) % 2 ether;
        if (amount == 0) return;
        vault.fundNative{value: amount}();
        totalFunded += amount;
    }

    function claim(uint96 seed) external {
        uint256 requested = (uint256(seed) % 2 ether) + 1;
        (bool success,) = address(vault).call(abi.encodeCall(FinanceVault.claim, (positionId, requested)));
        success;
    }
}

contract FinanceCapInvariantTest {
    FinanceVault private vault;
    FinanceCapHandler private handler;

    function setUp() public {
        vault = new FinanceVault(address(new InvariantFinanceToken()));
        handler = new FinanceCapHandler(vault);
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function invariant_lifetimePayoutNeverExceedsPrincipalTimesMultiple() external view {
        (,, uint256 principal, uint256 claimed, uint16 multipleBps,) = vault.positions(handler.positionId());
        require(claimed <= principal * multipleBps / 10_000, "finance cap exceeded");
    }
}
