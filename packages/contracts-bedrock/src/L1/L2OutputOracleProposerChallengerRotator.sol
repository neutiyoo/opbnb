// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { L2OutputOracle } from "src/L1/L2OutputOracle.sol";

/// @custom:proxied
/// @title L2OutputOracleProposerChallengerRotator
/// @notice Temporary L2OutputOracle implementation used to rotate proposer and challenger.
contract L2OutputOracleProposerChallengerRotator is L2OutputOracle {
    /// @notice Emitted when the proposer and challenger are rotated.
    event ProposerAndChallengerRotated(
        address oldProposer, address oldChallenger, address newProposer, address newChallenger
    );

    /// @notice Rotates the proposer and challenger addresses.
    /// @dev This function is intentionally permissionless. The implementation must only be exposed inside an atomic
    ///      upgrade-call-restore batch controlled by the proxy admin.
    /// @param _proposer New proposer address.
    /// @param _challenger New challenger address.
    function rotateProposerAndChallenger(address _proposer, address _challenger) external {
        require(_proposer != address(0), "L2OutputOracle: proposer cannot be zero address");
        require(_challenger != address(0), "L2OutputOracle: challenger cannot be zero address");

        emit ProposerAndChallengerRotated(proposer, challenger, _proposer, _challenger);

        proposer = _proposer;
        challenger = _challenger;
    }
}
