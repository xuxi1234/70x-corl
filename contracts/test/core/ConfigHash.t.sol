// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ConfigHash} from "../../src/core/ConfigHash.sol";
import {LaunchTypes} from "../../src/core/LaunchTypes.sol";

interface Vm {
    function readFile(string calldata path) external view returns (string memory data);
    function parseJsonString(string calldata json, string calldata key) external pure returns (string memory value);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256 value);
    function parseJsonUintArray(string calldata json, string calldata key)
        external
        pure
        returns (uint256[] memory value);
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address value);
    function parseJsonBytes32(string calldata json, string calldata key) external pure returns (bytes32 value);
}

contract ConfigHashTest {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    string private constant FIXTURE_PATH = "../packages/protocol/fixtures/common-config.json";

    function testHashMatchesCrossLanguageFixture() public view {
        string memory json = VM.readFile(FIXTURE_PATH);
        uint256[] memory fixtureAllocations = VM.parseJsonUintArray(json, ".allocationBps");
        require(fixtureAllocations.length == 4, "fixture allocation length");

        uint16[4] memory allocationBps;
        for (uint256 index; index < allocationBps.length; ++index) {
            require(fixtureAllocations[index] <= type(uint16).max, "fixture allocation overflow");
            allocationBps[index] = uint16(fixtureAllocations[index]);
        }

        uint256 fixtureBuyTaxBps = VM.parseJsonUint(json, ".buyTaxBps");
        require(fixtureBuyTaxBps <= type(uint16).max, "fixture buy tax overflow");
        // Safe because the fixture value is bounded immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 buyTaxBps = uint16(fixtureBuyTaxBps);

        uint256 fixtureSellTaxBps = VM.parseJsonUint(json, ".sellTaxBps");
        require(fixtureSellTaxBps <= type(uint16).max, "fixture sell tax overflow");
        // Safe because the fixture value is bounded immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 sellTaxBps = uint16(fixtureSellTaxBps);

        uint256 fixtureLpMode = VM.parseJsonUint(json, ".lpMode");
        require(fixtureLpMode <= type(uint8).max, "fixture LP mode overflow");
        // Safe because the fixture value is bounded immediately above.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint8 lpMode = uint8(fixtureLpMode);

        LaunchTypes.CommonConfig memory config = LaunchTypes.CommonConfig({
            name: VM.parseJsonString(json, ".name"),
            symbol: VM.parseJsonString(json, ".symbol"),
            supply: _parseDecimalUint(VM.parseJsonString(json, ".supply")),
            buyTaxBps: buyTaxBps,
            sellTaxBps: sellTaxBps,
            receiver: VM.parseJsonAddress(json, ".receiver"),
            rewardToken: VM.parseJsonAddress(json, ".rewardToken"),
            rewardThreshold: _parseDecimalUint(VM.parseJsonString(json, ".rewardThreshold")),
            lpMode: lpMode,
            allocationBps: allocationBps,
            metadataHash: VM.parseJsonBytes32(json, ".metadataHash")
        });

        require(ConfigHash.hash(config) == VM.parseJsonBytes32(json, ".expectedHash"), "fixture hash mismatch");
    }

    function _parseDecimalUint(string memory value) private pure returns (uint256 result) {
        bytes memory digits = bytes(value);
        require(digits.length != 0, "empty decimal fixture value");

        for (uint256 index; index < digits.length; ++index) {
            uint8 digit = uint8(digits[index]);
            require(digit >= 48 && digit <= 57, "invalid decimal fixture value");
            result = result * 10 + (digit - 48);
        }
    }
}
