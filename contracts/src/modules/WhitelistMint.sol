// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

contract WhitelistMint {
    error InvalidDeadline(uint64 deadline);
    error InvalidOwner();
    error InvalidRoot();
    error RestrictionExpired();
    error UnauthorizedOwner(address caller);

    event EpochAppended(uint256 indexed epoch, bytes32 root);

    address public immutable owner;
    uint64 public immutable deadline;
    bytes32[] private roots;

    constructor(address owner_, bytes32 initialRoot, uint64 deadline_) {
        if (owner_ == address(0)) revert InvalidOwner();
        if (initialRoot == bytes32(0)) revert InvalidRoot();
        // Whitelist availability is intentionally bounded by immutable chain time.
        // forge-lint: disable-next-line(block-timestamp)
        if (deadline_ <= block.timestamp || deadline_ > block.timestamp + 24 hours) revert InvalidDeadline(deadline_);
        owner = owner_;
        deadline = deadline_;
        roots.push(initialRoot);
        emit EpochAppended(0, initialRoot);
    }

    function appendEpoch(bytes32 root) external {
        if (msg.sender != owner) revert UnauthorizedOwner(msg.sender);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= deadline) revert RestrictionExpired();
        if (root == bytes32(0)) revert InvalidRoot();
        roots.push(root);
        emit EpochAppended(roots.length - 1, root);
    }

    function isPublic() public view returns (bool) {
        // forge-lint: disable-next-line(block-timestamp)
        return block.timestamp >= deadline;
    }

    function epochCount() external view returns (uint256) {
        return roots.length;
    }

    function rootAt(uint256 epoch) external view returns (bytes32) {
        return roots[epoch];
    }

    function isAllowed(uint256 epoch, address account, bytes32[] calldata proof) external view returns (bool) {
        if (isPublic()) return true;
        if (epoch >= roots.length) return false;
        bytes32 computed = keccak256(abi.encodePacked(account));
        for (uint256 index; index < proof.length; ++index) {
            bytes32 sibling = proof[index];
            computed = computed < sibling
                ? keccak256(abi.encodePacked(computed, sibling))
                : keccak256(abi.encodePacked(sibling, computed));
        }
        return computed == roots[epoch];
    }
}
