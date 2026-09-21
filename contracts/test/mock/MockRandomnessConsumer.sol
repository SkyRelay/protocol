// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISkyRelayEntropy} from "../../src/interfaces/ISkyRelay.sol";

/// @title MockRandomnessConsumer
/// @notice Demonstration only: request words from `SkyRelayEntropy` and, once
///         the serving round has a seed, settle on the first word. Not a product.
/// @dev The sighting gate and the commit-reveal live in the entropy contract.
///      This mock only shows a consumer can request during round R, wait for
///      round R+1, and read the words.
contract MockRandomnessConsumer {
    ISkyRelayEntropy public immutable entropy;

    struct Draw {
        bytes32 requestId;
        uint64 servingRound;
        uint32 numWords;
        bool settled;
        uint256 firstWord;
    }

    uint256 public totalDraws;
    mapping(uint256 => Draw) public draws;

    event DrawRequested(uint256 indexed drawId, bytes32 indexed requestId, uint64 servingRound, uint32 numWords);
    event DrawSettled(uint256 indexed drawId, uint256 firstWord);
    event DrawReserviced(uint256 indexed drawId, uint64 servingRound);

    error ZeroAddress();
    error UnknownDraw();
    error AlreadySettled();

    constructor(ISkyRelayEntropy entropy_) {
        if (address(entropy_) == address(0)) revert ZeroAddress();
        entropy = entropy_;
    }

    /// @notice Request `numWords`. The serving round is the one the entropy
    ///         contract assigns — the round after the current one.
    function requestDraw(uint32 numWords) external returns (uint256 drawId) {
        (bytes32 requestId, uint64 servingRound) = entropy.requestRandomness(numWords);
        drawId = ++totalDraws;
        draws[drawId] =
            Draw({requestId: requestId, servingRound: servingRound, numWords: numWords, settled: false, firstWord: 0});
        emit DrawRequested(drawId, requestId, servingRound, numWords);
    }

    /// @notice Read the words and store the first. Reverts until the serving
    ///         round has finalized with a seed.
    function settle(uint256 drawId) external returns (uint256 firstWord) {
        Draw storage d = draws[drawId];
        if (d.requestId == bytes32(0)) revert UnknownDraw();
        if (d.settled) revert AlreadySettled();
        uint256[] memory words = entropy.randomWords(d.requestId);
        d.settled = true;
        d.firstWord = words[0];
        emit DrawSettled(drawId, words[0]);
        return words[0];
    }

    /// @notice If the assigned round finalized with no reveals, point this
    ///         draw at a later round. The entropy contract still requires the
    ///         caller to be the original requester, which is this contract.
    function reservice(uint256 drawId) external returns (uint64 servingRound) {
        Draw storage d = draws[drawId];
        if (d.requestId == bytes32(0)) revert UnknownDraw();
        if (d.settled) revert AlreadySettled();
        servingRound = entropy.reservice(d.requestId);
        d.servingRound = servingRound;
        emit DrawReserviced(drawId, servingRound);
    }
}
