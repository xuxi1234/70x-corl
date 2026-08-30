// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {StandardTemplateV1} from "./StandardTemplateV1.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {LaunchLimits} from "../modules/LaunchLimits.sol";

contract LaunchLimitMintVault is MintVault {
    LaunchLimits public immutable limits;

    constructor(
        address creator_,
        address executor_,
        string memory name_,
        string memory symbol_,
        uint256 claimAllocation_,
        uint256 launchAllocation_,
        uint256 minimumOutput_,
        uint32 shares_,
        uint96 price_,
        uint32[] memory durations_,
        uint16[] memory limits_
    )
        MintVault(
            creator_, executor_, name_, symbol_, claimAllocation_, launchAllocation_, minimumOutput_, shares_, price_
        )
    {
        limits = new LaunchLimits(address(this), address(token), executor_, durations_, limits_);
    }

    function _onTokenTransfer(address from, address to, uint256) internal view override {
        limits.validateTransfer(from, to);
    }

    function _onLiquidityTokenSet(address pair_) internal override {
        limits.activate(pair_);
    }
}

contract LaunchLimitTemplateV1 is ITemplate {
    struct Config {
        StandardTemplateV1.StandardConfig launch;
        uint32[] durationsMinutes;
        uint16[] maximumWalletBps;
    }
    error InvalidEncoding();
    error InvalidLaunchConfig();
    error UnauthorizedFactory(address caller);
    address public immutable factory;
    address public immutable finalizationExecutor;
    bytes32 public constant TEMPLATE_ID = keccak256("LAUNCH_LIMIT");
    uint32 public constant VERSION = 1;

    constructor(address factory_, address executor_) {
        require(factory_ != address(0) && executor_.code.length != 0, "dependency");
        factory = factory_;
        finalizationExecutor = executor_;
    }

    function deploy(address creator, bytes calldata commonBytes, bytes calldata configBytes)
        external
        returns (address token, address vault)
    {
        if (msg.sender != factory) revert UnauthorizedFactory(msg.sender);
        LaunchTypes.CommonConfig memory common = abi.decode(commonBytes, (LaunchTypes.CommonConfig));
        Config memory config = abi.decode(configBytes, (Config));
        if (
            keccak256(commonBytes) != keccak256(abi.encode(common))
                || keccak256(configBytes) != keccak256(abi.encode(config))
        ) revert InvalidEncoding();
        _validate(config.launch);
        uint256 supply = common.supply * 1 ether;
        uint256 claimAllocation = supply * config.launch.claimTokenBps / 10_000;
        LaunchLimitMintVault deployed = new LaunchLimitMintVault(
            creator,
            finalizationExecutor,
            common.name,
            common.symbol,
            claimAllocation,
            supply - claimAllocation,
            config.launch.minimumLiquidityOutput,
            config.launch.totalShares,
            config.launch.pricePerShare,
            config.durationsMinutes,
            config.maximumWalletBps
        );
        token = address(deployed.token());
        vault = address(deployed);
    }

    function _validate(StandardTemplateV1.StandardConfig memory config) private pure {
        if (
            config.totalShares == 0 || config.pricePerShare == 0 || config.claimTokenBps == 0
                || config.claimTokenBps >= 10_000 || config.minimumLiquidityOutput == 0
        ) revert InvalidLaunchConfig();
    }
}
