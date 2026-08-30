// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IFinanceAsset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address owner, address recipient, uint256 amount) external returns (bool);
}

contract FinanceVault {
    struct Position {
        address owner;
        address asset;
        uint256 principal;
        uint256 claimed;
        uint16 exitMultipleBps;
        bool closed;
    }

    error InvalidAmount();
    error InvalidMultiple(uint16 multipleBps);
    error InvalidSupportedToken();
    error NothingAvailable();
    error PositionClosed(uint256 positionId);
    error ReentrantCall();
    error TokenTransferFailed();
    error UnauthorizedPosition(address caller, uint256 positionId);

    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        address indexed asset,
        uint256 principal,
        uint16 exitMultipleBps
    );
    event PositionClaimed(uint256 indexed positionId, uint256 amount, uint256 lifetimeClaimed, bool closed);
    event Funded(address indexed asset, address indexed funder, uint256 amount);

    address public immutable supportedToken;
    uint256 public nextPositionId;
    mapping(uint256 positionId => Position position) public positions;
    bool private entered;

    constructor(address supportedToken_) {
        if (supportedToken_.code.length == 0) revert InvalidSupportedToken();
        supportedToken = supportedToken_;
    }

    modifier nonReentrant() {
        if (entered) revert ReentrantCall();
        entered = true;
        _;
        entered = false;
    }

    function openNative(uint16 exitMultipleBps) external payable nonReentrant returns (uint256 positionId) {
        if (msg.value == 0) revert InvalidAmount();
        positionId = _open(msg.sender, address(0), msg.value, exitMultipleBps);
    }

    function openToken(uint256 amount, uint16 exitMultipleBps) external nonReentrant returns (uint256 positionId) {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IFinanceAsset(supportedToken).balanceOf(address(this));
        if (!IFinanceAsset(supportedToken).transferFrom(msg.sender, address(this), amount)) {
            revert TokenTransferFailed();
        }
        if (IFinanceAsset(supportedToken).balanceOf(address(this)) - beforeBalance != amount) {
            revert TokenTransferFailed();
        }
        positionId = _open(msg.sender, supportedToken, amount, exitMultipleBps);
    }

    function fundNative() external payable {
        if (msg.value == 0) revert InvalidAmount();
        emit Funded(address(0), msg.sender, msg.value);
    }

    function fundToken(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = IFinanceAsset(supportedToken).balanceOf(address(this));
        if (!IFinanceAsset(supportedToken).transferFrom(msg.sender, address(this), amount)) {
            revert TokenTransferFailed();
        }
        if (IFinanceAsset(supportedToken).balanceOf(address(this)) - beforeBalance != amount) {
            revert TokenTransferFailed();
        }
        emit Funded(supportedToken, msg.sender, amount);
    }

    function claim(uint256 positionId, uint256 requested) external nonReentrant returns (uint256 amount) {
        Position storage position = positions[positionId];
        if (position.owner != msg.sender) revert UnauthorizedPosition(msg.sender, positionId);
        if (position.closed) revert PositionClosed(positionId);
        uint256 cap = position.principal * position.exitMultipleBps / 10_000;
        uint256 remaining = cap - position.claimed;
        uint256 liquidity = position.asset == address(0)
            ? address(this).balance
            : IFinanceAsset(position.asset).balanceOf(address(this));
        amount = requested < remaining ? requested : remaining;
        if (amount > liquidity) amount = liquidity;
        if (amount == 0) revert NothingAvailable();

        position.claimed += amount;
        if (position.claimed == cap) position.closed = true;
        if (position.asset == address(0)) {
            (bool success,) = payable(msg.sender).call{value: amount}("");
            if (!success) revert TokenTransferFailed();
        } else {
            uint256 beforeBalance = IFinanceAsset(position.asset).balanceOf(address(this));
            if (!IFinanceAsset(position.asset).transfer(msg.sender, amount)) revert TokenTransferFailed();
            if (beforeBalance - IFinanceAsset(position.asset).balanceOf(address(this)) != amount) {
                revert TokenTransferFailed();
            }
        }
        emit PositionClaimed(positionId, amount, position.claimed, position.closed);
    }

    function remainingPayout(uint256 positionId) external view returns (uint256) {
        Position storage position = positions[positionId];
        return position.principal * position.exitMultipleBps / 10_000 - position.claimed;
    }

    function _open(address owner, address asset, uint256 principal, uint16 multipleBps)
        private
        returns (uint256 positionId)
    {
        if (multipleBps < 10_000 || multipleBps > 50_000 || multipleBps % 1_000 != 0) {
            revert InvalidMultiple(multipleBps);
        }
        positionId = nextPositionId++;
        positions[positionId] = Position(owner, asset, principal, 0, multipleBps, false);
        emit PositionOpened(positionId, owner, asset, principal, multipleBps);
    }
}
