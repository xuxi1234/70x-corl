// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchTypes} from "../core/LaunchTypes.sol";
import {ITemplate} from "../interfaces/ITemplate.sol";
import {StandardTemplateV1} from "./StandardTemplateV1.sol";
import {MintVault} from "../vaults/MintVault.sol";
import {WhitelistMint} from "../modules/WhitelistMint.sol";

contract WhitelistMintVault is MintVault {
    error WhitelistProofRequired();
    error InvalidWhitelistProof();
    WhitelistMint public immutable whitelist;

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
        bytes32 root_,
        uint64 deadline_
    )
        MintVault(
            creator_, executor_, name_, symbol_, claimAllocation_, launchAllocation_, minimumOutput_, shares_, price_
        )
    {
        whitelist = new WhitelistMint(creator_, root_, deadline_);
    }

    function mint(uint32 shares) public payable override {
        if (!whitelist.isPublic()) revert WhitelistProofRequired();
        super.mint(shares);
    }

    function mintWithProof(uint32 shares, uint256 epoch, bytes32[] calldata proof) external payable {
        if (!whitelist.isAllowed(epoch, msg.sender, proof)) revert InvalidWhitelistProof();
        super.mint(shares);
    }
}

contract WhitelistTemplateV1 is ITemplate {
    struct Config {
        StandardTemplateV1.StandardConfig launch;
        bytes32 initialRoot;
        uint64 whitelistDeadline;
    }
    error InvalidEncoding();
    error InvalidLaunchConfig();
    error UnauthorizedFactory(address caller);
    address public immutable factory;
    address public immutable finalizationExecutor;
    bytes32 public constant TEMPLATE_ID = keccak256("WHITELIST");
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
        WhitelistMintVault deployed = new WhitelistMintVault(
            creator,
            finalizationExecutor,
            common.name,
            common.symbol,
            claimAllocation,
            supply - claimAllocation,
            config.launch.minimumLiquidityOutput,
            config.launch.totalShares,
            config.launch.pricePerShare,
            config.initialRoot,
            config.whitelistDeadline
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
