// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract LaunchToken {
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    error InsufficientAllowance(address spender, uint256 allowance, uint256 required);
    error InsufficientBalance(address account, uint256 balance, uint256 required);
    error InvalidReceiver();
    error InvalidSupply();
    error InvalidTaxBps(uint16 taxBps);
    error InvalidTaxProcessor(address processor);
    error ProjectConfigHashAlreadySet();
    error TaxAlreadyConfigured();
    error TaxNotConfigured();
    error UnauthorizedObserver(address caller);

    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event TaxExemptionSet(address indexed account, bool exempt);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    address public immutable transferObserver;
    address public taxProcessor;
    address public liquidityPair;
    uint16 public buyTaxBps;
    uint16 public sellTaxBps;
    bytes32 public projectConfigHash;

    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address account => bool exempt) public isTaxExempt;

    constructor(string memory name_, string memory symbol_, uint256 supply_, address vault) {
        if (vault == address(0)) revert InvalidReceiver();
        if (supply_ == 0) revert InvalidSupply();

        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        transferObserver = vault;
        balanceOf[vault] = supply_;
        emit Transfer(address(0), vault, supply_);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function setProjectConfigHash(bytes32 fullConfigHash) external {
        if (msg.sender != transferObserver) revert UnauthorizedObserver(msg.sender);
        if (projectConfigHash != bytes32(0) || fullConfigHash == bytes32(0)) revert ProjectConfigHashAlreadySet();
        projectConfigHash = fullConfigHash;
    }

    function configureTax(address processor, uint16 buyTax, uint16 sellTax) external {
        if (msg.sender != transferObserver) revert UnauthorizedObserver(msg.sender);
        if (taxProcessor != address(0)) revert TaxAlreadyConfigured();
        if (processor.code.length == 0) revert InvalidTaxProcessor(processor);
        if (buyTax > 1_000) revert InvalidTaxBps(buyTax);
        if (sellTax > 1_000) revert InvalidTaxBps(sellTax);
        taxProcessor = processor;
        buyTaxBps = buyTax;
        sellTaxBps = sellTax;
    }

    function activateTax(address pair) external {
        if (msg.sender != transferObserver) revert UnauthorizedObserver(msg.sender);
        if (taxProcessor == address(0)) revert TaxNotConfigured();
        if (liquidityPair != address(0) || pair.code.length == 0) revert TaxAlreadyConfigured();
        liquidityPair = pair;
    }

    function setTaxExempt(address account, bool exempt) external {
        if (msg.sender != transferObserver) revert UnauthorizedObserver(msg.sender);
        if (account == address(0)) revert InvalidReceiver();
        isTaxExempt[account] = exempt;
        emit TaxExemptionSet(account, exempt);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(msg.sender, currentAllowance, amount);
            }
            unchecked {
                allowance[from][msg.sender] = currentAllowance - amount;
            }
            emit Approval(from, msg.sender, currentAllowance - amount);
        }

        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert InvalidReceiver();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);

        uint256 taxAmount;
        address pair = liquidityPair;
        address processor = taxProcessor;
        if (
            pair != address(0) && from != processor && to != processor && to != DEAD_ADDRESS && !isTaxExempt[from]
                && !isTaxExempt[to]
        ) {
            uint16 taxBps;
            if (from == pair) {
                taxBps = buyTaxBps;
            } else if (to == pair) {
                taxBps = sellTaxBps;
            }
            taxAmount = amount * taxBps / 10_000;
        }
        uint256 delivered = amount - taxAmount;

        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += delivered;
            if (taxAmount != 0) balanceOf[processor] += taxAmount;
        }
        emit Transfer(from, to, delivered);
        ILaunchTransferObserver(transferObserver).onTokenTransfer(from, to, delivered);
        if (taxAmount != 0) {
            emit Transfer(from, processor, taxAmount);
            ILaunchTransferObserver(transferObserver).onTokenTransfer(from, processor, taxAmount);
            ILaunchTransferObserver(transferObserver).onTaxCollected(taxAmount);
        }
    }
}

interface ILaunchTransferObserver {
    function onTokenTransfer(address from, address to, uint256 amount) external;
    function onTaxCollected(uint256 amount) external;
}
