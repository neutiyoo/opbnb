// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { console2 as console } from "forge-std/console2.sol";
import { Script } from "forge-std/Script.sol";
import { GnosisSafe } from "safe-contracts/GnosisSafe.sol";
import { Enum } from "safe-contracts/common/Enum.sol";
import { MultiSendCallOnly } from "safe-contracts/libraries/MultiSendCallOnly.sol";
import { L2OutputOracle } from "src/L1/L2OutputOracle.sol";
import { L2OutputOracleProposerChallengerRotator } from "src/L1/L2OutputOracleProposerChallengerRotator.sol";
import { ProxyAdmin } from "src/universal/ProxyAdmin.sol";

/// @title L2OutputOracleProposerChallengerRotation
/// @notice Generates and rehearses the atomic Matchain proposer/challenger rotation batch.
contract L2OutputOracleProposerChallengerRotation is Script {
    address internal constant MATCHAIN_L2_OUTPUT_ORACLE_PROXY = 0xc18EBF62817A4ec94C5a4f4978E913975baa6Fc1;
    address internal constant MATCHAIN_PROXY_ADMIN = 0x689B77b3564f57d338E6f3E108C60bec937C8510;
    address internal constant MATCHAIN_OWNER_SAFE = 0x00D576F15A953296521E265d358eF8ECF305fe10;
    address internal constant MATCHAIN_OLD_IMPL = 0x80f4b9B3bF1A9d08d8961D9C634e4E5B650cF467;
    address internal constant MULTISEND_CALL_ONLY = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;

    address internal constant CURRENT_PROPOSER = 0x27927B1c254F44E4daa003814746c96d6Db4134d;
    address internal constant CURRENT_CHALLENGER = 0x0D52D61De226cb30f03b11FC0b619C7BCa6e0b57;

    address internal constant NEW_PROPOSER = 0xf77d54F74601edE8aD6b228c52b736242CF7Ff58;

    struct HandoverConfig {
        address temporaryImplementation;
        address newChallenger;
    }

    struct BatchCalldata {
        bytes upgradeToTemporaryImplementation;
        bytes rotateProposerAndChallenger;
        bytes restoreOriginalImplementation;
        bytes packedTransactions;
        bytes multiSendCall;
    }

    struct OracleState {
        uint256 startingBlockNumber;
        uint256 startingTimestamp;
        uint256 submissionInterval;
        uint256 l2BlockTime;
        uint256 finalizationPeriodSeconds;
        uint256 latestBlockNumber;
        uint256 nextOutputIndex;
    }

    /// @notice Deploys the temporary permissionless implementation.
    function deployRotator() public {
        vm.startBroadcast();
        L2OutputOracleProposerChallengerRotator rotator = new L2OutputOracleProposerChallengerRotator();
        vm.stopBroadcast();

        console.log("Temporary implementation:", address(rotator));
    }

    /// @notice Prints the single Safe MultiSend transaction.
    function printMatchainCalldata() public view {
        HandoverConfig memory cfg = _configFromEnvironment();
        _checkConfig(cfg);
        _checkLiveState();

        BatchCalldata memory batch = _buildBatch(cfg);

        console.log("SAFE BATCH: atomic L2OutputOracle proposer/challenger rotation");
        console.log("Safe:", MATCHAIN_OWNER_SAFE);
        console.log("Expected current Safe nonce:", GnosisSafe(payable(MATCHAIN_OWNER_SAFE)).nonce());
        console.log("To (MultiSendCallOnly):", MULTISEND_CALL_ONLY);
        console.log("Value: 0");
        console.log("Operation: 1 (DelegateCall)");
        console.log("Data: MultiSendCallOnly.multiSend(packedTransactions)");
        console.logBytes(batch.multiSendCall);

        _printInnerCall(1, MATCHAIN_PROXY_ADMIN, batch.upgradeToTemporaryImplementation);
        _printInnerCall(2, MATCHAIN_L2_OUTPUT_ORACLE_PROXY, batch.rotateProposerAndChallenger);
        _printInnerCall(3, MATCHAIN_PROXY_ADMIN, batch.restoreOriginalImplementation);
    }

    /// @notice Rehearses the actual Safe MultiSend execution on a BSC fork.
    function simulateMatchain() public {
        _checkLiveState();

        HandoverConfig memory cfg = HandoverConfig({
            temporaryImplementation: address(new L2OutputOracleProposerChallengerRotator()),
            newChallenger: vm.envAddress("NEW_CHALLENGER")
        });
        _checkConfig(cfg);

        ProxyAdmin proxyAdmin = ProxyAdmin(MATCHAIN_PROXY_ADMIN);
        L2OutputOracle oracle = L2OutputOracle(MATCHAIN_L2_OUTPUT_ORACLE_PROXY);
        GnosisSafe safe = GnosisSafe(payable(MATCHAIN_OWNER_SAFE));

        OracleState memory oldState = _oracleState(oracle);
        uint256 oldSafeNonce = safe.nonce();

        BatchCalldata memory batch = _buildBatch(cfg);
        bytes32 safeTxHash = safe.getTransactionHash(
            MULTISEND_CALL_ONLY,
            0,
            batch.multiSendCall,
            Enum.Operation.DelegateCall,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            oldSafeNonce
        );

        address[] memory owners = safe.getOwners();
        _sortAddresses(owners);
        uint256 threshold = safe.getThreshold();
        require(threshold > 0 && threshold <= owners.length, "invalid Safe threshold");

        for (uint256 i; i < threshold; i++) {
            vm.prank(owners[i]);
            safe.approveHash(safeTxHash);
        }

        bytes memory signatures = _approvedHashSignatures(owners, threshold);
        bool success = safe.execTransaction(
            MULTISEND_CALL_ONLY,
            0,
            batch.multiSendCall,
            Enum.Operation.DelegateCall,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            signatures
        );
        require(success, "Safe MultiSend execution failed");

        require(safe.nonce() == oldSafeNonce + 1, "Safe nonce did not increment once");
        require(
            proxyAdmin.getProxyImplementation(MATCHAIN_L2_OUTPUT_ORACLE_PROXY) == MATCHAIN_OLD_IMPL,
            "old impl not restored"
        );
        require(oracle.proposer() == NEW_PROPOSER, "proposer not rotated");
        require(oracle.challenger() == cfg.newChallenger, "challenger not rotated");
        _assertOracleStateUnchanged(oracle, oldState);

        console.log("Matchain Safe batch simulation succeeded");
        console.log("Temporary implementation:", cfg.temporaryImplementation);
        console.log("New proposer:", NEW_PROPOSER);
        console.log("New challenger:", cfg.newChallenger);
        console.log("Safe nonce before:", oldSafeNonce);
        console.log("Safe nonce after:", safe.nonce());
    }

    function _configFromEnvironment() internal view returns (HandoverConfig memory) {
        return HandoverConfig({
            temporaryImplementation: vm.envAddress("TEMP_IMPL"), newChallenger: vm.envAddress("NEW_CHALLENGER")
        });
    }

    function _buildBatch(HandoverConfig memory _cfg) internal pure returns (BatchCalldata memory batch_) {
        batch_.upgradeToTemporaryImplementation = abi.encodeCall(
            ProxyAdmin.upgrade, (payable(MATCHAIN_L2_OUTPUT_ORACLE_PROXY), _cfg.temporaryImplementation)
        );
        batch_.rotateProposerAndChallenger = abi.encodeCall(
            L2OutputOracleProposerChallengerRotator.rotateProposerAndChallenger, (NEW_PROPOSER, _cfg.newChallenger)
        );
        batch_.restoreOriginalImplementation =
            abi.encodeCall(ProxyAdmin.upgrade, (payable(MATCHAIN_L2_OUTPUT_ORACLE_PROXY), MATCHAIN_OLD_IMPL));

        batch_.packedTransactions = bytes.concat(
            _encodeCall(MATCHAIN_PROXY_ADMIN, batch_.upgradeToTemporaryImplementation),
            _encodeCall(MATCHAIN_L2_OUTPUT_ORACLE_PROXY, batch_.rotateProposerAndChallenger),
            _encodeCall(MATCHAIN_PROXY_ADMIN, batch_.restoreOriginalImplementation)
        );
        batch_.multiSendCall = abi.encodeCall(MultiSendCallOnly.multiSend, (batch_.packedTransactions));
    }

    function _checkLiveState() internal view {
        ProxyAdmin proxyAdmin = ProxyAdmin(MATCHAIN_PROXY_ADMIN);
        L2OutputOracle oracle = L2OutputOracle(MATCHAIN_L2_OUTPUT_ORACLE_PROXY);

        require(proxyAdmin.owner() == MATCHAIN_OWNER_SAFE, "unexpected ProxyAdmin owner");
        require(
            proxyAdmin.getProxyImplementation(MATCHAIN_L2_OUTPUT_ORACLE_PROXY) == MATCHAIN_OLD_IMPL,
            "unexpected L2OO implementation"
        );
        require(oracle.proposer() == CURRENT_PROPOSER, "unexpected proposer");
        require(oracle.challenger() == CURRENT_CHALLENGER, "unexpected challenger");
    }

    function _checkConfig(HandoverConfig memory _cfg) internal pure {
        require(_cfg.temporaryImplementation != address(0), "missing temporary implementation");
        require(_cfg.temporaryImplementation != MATCHAIN_OLD_IMPL, "temporary implementation equals old impl");
        require(_cfg.newChallenger != address(0), "missing new challenger");
        require(NEW_PROPOSER != CURRENT_PROPOSER, "proposer unchanged");
        require(_cfg.newChallenger != CURRENT_CHALLENGER, "challenger unchanged");
    }

    function _oracleState(L2OutputOracle _oracle) internal view returns (OracleState memory) {
        return OracleState({
            startingBlockNumber: _oracle.startingBlockNumber(),
            startingTimestamp: _oracle.startingTimestamp(),
            submissionInterval: _oracle.submissionInterval(),
            l2BlockTime: _oracle.l2BlockTime(),
            finalizationPeriodSeconds: _oracle.finalizationPeriodSeconds(),
            latestBlockNumber: _oracle.latestBlockNumber(),
            nextOutputIndex: _oracle.nextOutputIndex()
        });
    }

    function _assertOracleStateUnchanged(L2OutputOracle _oracle, OracleState memory _oldState) internal view {
        require(_oracle.startingBlockNumber() == _oldState.startingBlockNumber, "startingBlockNumber changed");
        require(_oracle.startingTimestamp() == _oldState.startingTimestamp, "startingTimestamp changed");
        require(_oracle.submissionInterval() == _oldState.submissionInterval, "submissionInterval changed");
        require(_oracle.l2BlockTime() == _oldState.l2BlockTime, "l2BlockTime changed");
        require(
            _oracle.finalizationPeriodSeconds() == _oldState.finalizationPeriodSeconds,
            "finalizationPeriodSeconds changed"
        );
        require(_oracle.latestBlockNumber() == _oldState.latestBlockNumber, "latestBlockNumber changed");
        require(_oracle.nextOutputIndex() == _oldState.nextOutputIndex, "nextOutputIndex changed");
    }

    function _encodeCall(address _to, bytes memory _data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Enum.Operation.Call), _to, uint256(0), uint256(_data.length), _data);
    }

    function _sortAddresses(address[] memory _addresses) internal pure {
        for (uint256 i = 1; i < _addresses.length; i++) {
            address value = _addresses[i];
            uint256 j = i;
            while (j > 0 && uint160(_addresses[j - 1]) > uint160(value)) {
                _addresses[j] = _addresses[j - 1];
                j--;
            }
            _addresses[j] = value;
        }
    }

    function _approvedHashSignatures(
        address[] memory _owners,
        uint256 _threshold
    )
        internal
        pure
        returns (bytes memory signatures_)
    {
        for (uint256 i; i < _threshold; i++) {
            signatures_ = bytes.concat(
                signatures_, abi.encodePacked(bytes32(uint256(uint160(_owners[i]))), bytes32(0), uint8(1))
            );
        }
    }

    function _printInnerCall(uint256 _index, address _to, bytes memory _data) internal pure {
        console.log("Inner call index:", _index);
        console.log("To:", _to);
        console.log("Value: 0");
        console.log("Operation: 0 (Call)");
        console.logBytes(_data);
    }
}
