// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "./Ownable2Step.sol";

contract TemplateRegistry is Ownable2Step {
    error InvalidImplementation();
    error TemplateAlreadyRegistered(bytes32 id, uint32 version);

    event TemplateRegistered(
        bytes32 indexed id, uint32 indexed version, address indexed implementation, bytes32 schemaHash
    );

    struct Template {
        address implementation;
        bytes32 schemaHash;
    }

    mapping(bytes32 id => mapping(uint32 version => Template template)) private _templates;

    constructor(address initialOwner) Ownable2Step(initialOwner) {}

    function register(bytes32 id, uint32 version, address implementation, bytes32 schemaHash) external onlyOwner {
        if (implementation == address(0)) revert InvalidImplementation();

        Template storage template = _templates[id][version];
        if (template.implementation != address(0)) revert TemplateAlreadyRegistered(id, version);

        template.implementation = implementation;
        template.schemaHash = schemaHash;
        emit TemplateRegistered(id, version, implementation, schemaHash);
    }

    function resolve(bytes32 id, uint32 version) external view returns (address implementation, bytes32 schemaHash) {
        Template storage template = _templates[id][version];
        return (template.implementation, template.schemaHash);
    }
}
