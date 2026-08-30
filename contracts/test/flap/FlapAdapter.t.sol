// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlapAdapter} from "../../src/interfaces/IFlapAdapter.sol";
import {FlapAdapterV1} from "../../src/adapters/FlapAdapterV1.sol";

interface Vm {
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function expectRevert() external;
}

contract AdapterToken {
    mapping(address => uint256) public balanceOf;
    uint256 public sellProtectedUntil;

    constructor(uint256 until) {
        sellProtectedUntil = until;
    }

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        return true;
    }
}

contract AdapterPair {}

contract AdapterPoolAsset {}

contract PortalBoundary {
    bytes4 public lastSelector;
    AdapterToken public immutable token = new AdapterToken(type(uint256).max);
    AdapterPair public immutable pair = new AdapterPair();

    fallback() external payable {
        lastSelector = msg.sig;
        if (msg.sig == hex"2e2fdbd9") {
            token.mint(msg.sender, 100 ether);
            address deployed = address(token);
            assembly ("memory-safe") {
                mstore(0, deployed)
                return(0, 0x20)
            }
        }

        address recipient;
        assembly ("memory-safe") {
            recipient := calldataload(sub(calldatasize(), 0x20))
        }
        token.mint(recipient, 100 ether);
        bytes memory result = abi.encode(address(token), address(pair), 100 ether);
        assembly ("memory-safe") {
            return(add(result, 0x20), mload(result))
        }
    }
}

contract FlapAdapterTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function flapLaunchConfig()
        external
        pure
        returns (string memory, string memory, string memory, uint16, address, uint16[4] memory allocations, uint256)
    {
        allocations[1] = 10_000;
        return ("70X Test", "70XT", "ipfs://test", 300, address(0x1234), allocations, 0);
    }

    function testAdapterUsesOfficialPortalV5Selector() external {
        PortalBoundary portal = new PortalBoundary();
        address[] memory assets = new address[](0);
        FlapAdapterV1 adapter = new FlapAdapterV1(address(portal), assets);

        adapter.execute{value: 2 ether}(
            IFlapAdapter.LaunchRequest(
                0, address(0), bytes32(uint256(1)), 100 ether, block.timestamp + 1 hours, 5 minutes
            )
        );

        require(portal.lastSelector() == hex"2e2fdbd9", "must call Portal.newTokenV5");
        require(portal.token().balanceOf(address(this)) == 100 ether, "purchased tokens must reach caller");
    }

    function testAdapterPinsProtocolAndMeasuresPurchasedBalance() external {
        PortalBoundary protocol = new PortalBoundary();
        address[] memory assets = new address[](0);
        FlapAdapterV1 adapter = new FlapAdapterV1(address(protocol), assets);
        IFlapAdapter.LaunchResult memory result = adapter.execute{value: 2 ether}(
            IFlapAdapter.LaunchRequest(
                0, address(0), bytes32(uint256(1)), 100 ether, block.timestamp + 1 hours, 5 minutes
            )
        );
        require(result.nativeSpent == 2 ether && result.purchasedAmount == 100 ether, "result mismatch");
        require(AdapterToken(result.token).balanceOf(address(this)) == 100 ether, "recipient mismatch");
    }

    function testAdapterRejectsUnallowlistedAssetAndMismatchedPoolKind() external {
        PortalBoundary protocol = new PortalBoundary();
        address[] memory assets = new address[](0);
        FlapAdapterV1 adapter = new FlapAdapterV1(address(protocol), assets);
        AdapterPoolAsset asset = new AdapterPoolAsset();
        VM.expectRevert();
        adapter.execute(IFlapAdapter.LaunchRequest(1, address(asset), bytes32(0), 1, block.timestamp + 1, 0));
        VM.expectRevert();
        adapter.execute(IFlapAdapter.LaunchRequest(0, address(asset), bytes32(0), 1, block.timestamp + 1, 0));
    }

    function testAdapterRejectsProtocolCodeReplacement() external {
        PortalBoundary protocol = new PortalBoundary();
        address[] memory assets = new address[](0);
        FlapAdapterV1 adapter = new FlapAdapterV1(address(protocol), assets);

        VM.etch(address(protocol), hex"00");
        VM.expectRevert();
        adapter.execute(IFlapAdapter.LaunchRequest(0, address(0), bytes32(0), 1, block.timestamp + 1, 0));
    }
}
