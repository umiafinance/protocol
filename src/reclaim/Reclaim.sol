// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Claims.sol";
import "./StringUtils.sol";
import "./BytesUtils.sol";

/**
 * Reclaim Beacon contract
 */
contract Reclaim {
    struct Witness {
        /**
         * ETH address of the witness
         */
        address addr;
        /**
         * Host to connect to the witness
         */
        string host;
    }

    struct Epoch {
        /**
         * Epoch number
         */
        uint32 id;
        /**
         * when the epoch changed
         */
        uint32 timestampStart;
        /**
         * when the epoch will change
         */
        uint32 timestampEnd;
        /**
         * Witnesses for this epoch
         */
        Witness[] witnesses;
        /**
         * Minimum number of witnesses
         * required to create a claim
         *
         */
        uint8 minimumWitnessesForClaimCreation;
    }

    struct Proof {
        Claims.ClaimInfo claimInfo;
        Claims.SignedClaim signedClaim;
    }

    /**
     * list of all epochs
     */
    Epoch[] public epochs;

    /**
     * duration of each epoch.
     * is not a hard duration, but useful for
     * caching purposes
     *
     */
    uint32 public epochDurationS;

    /**
     * current epoch.
     * starts at 1, so that the first epoch is 1
     *
     */
    uint32 public currentEpoch;

    /**
     * mapping to track used proofs (prevents replay attacks)
     */
    mapping(bytes32 => bool) public usedProofs;

    event EpochAdded(Epoch epoch);
    event ProofUsed(bytes32 indexed identifier);
    /// @notice Emitted when `transferOwnership` nominates a new witness-set administrator.
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted when the nominee accepts and ownership actually moves.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    address public owner;

    /// @notice Nominee from step 1 of the two-step ownership handover. Zero when none is pending.
    address public pendingOwner;

    /**
     * Constructor to initialize the Reclaim contract
     * @notice Calls initialize on the base contracts
     */
    constructor() {
        epochDurationS = 1 days;
        owner = msg.sender;

        // Add initial epoch with witness
        currentEpoch = 1;
        Epoch storage epoch = epochs.push();
        epoch.id = currentEpoch;
        epoch.timestampStart = uint32(block.timestamp);
        epoch.timestampEnd = uint32(block.timestamp + epochDurationS);
        epoch.minimumWitnessesForClaimCreation = 1;
        epoch.witnesses
            .push(
                Witness({
                    addr: 0x244897572368Eadf65bfBc5aec98D8e5443a9072, host: "wss://attestor.reclaimprotocol.org/ws"
                })
            );
    }

    modifier onlyOwner() {
        require(owner == msg.sender, "Only Owner");
        _;
    }

    // ownership functions ---

    /**
     * @notice Step 1 of 2: nominate a new witness-set administrator.
     * @dev The witness set is the trust anchor for every proof this contract accepts, so the deploy
     *      EOA must be able to hand that power to a timelock or multisig. The handover is two-step so a
     *      mistyped address cannot permanently strand the epoch registry, and `pendingOwner` can be
     *      cleared by nominating `address(0)`.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /**
     * @notice Step 2 of 2: the nominee claims ownership.
     * @dev Must be called by the nominee itself, which proves the address is controlled and can transact.
     */
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not pending owner");
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    // epoch functions ---

    /**
     * Fetch an epoch
     * @param epoch the epoch number to fetch;
     * pass 0 to fetch the current epoch
     */
    function fetchEpoch(uint32 epoch) public view returns (Epoch memory) {
        if (epoch == 0) {
            return epochs[epochs.length - 1];
        }
        return epochs[epoch - 1];
    }

    /**
     * Get the witnesses that'll sign the claim
     */
    function fetchWitnessesForClaim(uint32 epoch, bytes32 identifier, uint32 timestampS)
        public
        view
        returns (Witness[] memory)
    {
        Epoch memory epochData = fetchEpoch(epoch);
        bytes memory completeInput = abi.encodePacked(
            StringUtils.bytes2str(abi.encodePacked(identifier)),
            "\n",
            StringUtils.uint2str(epoch),
            "\n",
            StringUtils.uint2str(epochData.minimumWitnessesForClaimCreation),
            "\n",
            StringUtils.uint2str(timestampS)
        );
        bytes memory completeHash = abi.encodePacked(keccak256(completeInput));

        Witness[] memory witnessesLeftList = epochData.witnesses;
        Witness[] memory selectedWitnesses = new Witness[](epochData.minimumWitnessesForClaimCreation);
        uint256 witnessesLeft = witnessesLeftList.length;

        uint256 byteOffset = 0;
        for (uint32 i = 0; i < epochData.minimumWitnessesForClaimCreation; i++) {
            uint256 randomSeed = BytesUtils.bytesToUInt(completeHash, byteOffset);
            uint256 witnessIndex = randomSeed % witnessesLeft;
            selectedWitnesses[i] = witnessesLeftList[witnessIndex];
            // remove the witness from the list of witnesses
            // we've utilised witness at index "idx"
            // we of course don't want to pick the same witness twice
            // so we remove it from the list of witnesses
            // and reduce the number of witnesses left to pick from
            // since solidity doesn't support "pop()" in memory arrays
            // we swap the last element with the element we want to remove
            witnessesLeftList[witnessIndex] = epochData.witnesses[witnessesLeft - 1];
            byteOffset = (byteOffset + 4) % completeHash.length;
            witnessesLeft -= 1;
        }

        return selectedWitnesses;
    }

    /**
     * Validate a proof without touching storage.
     *
     * @dev Split out of `verifyProof` so a consumer can verify a proof against its *own* replay ledger.
     *      `verifyProof` is permissionless and burns `usedProofs[identifier]`, which means any observer
     *      can copy a pending proof out of the mempool, burn it first, and permanently lock the rightful
     *      submitter out — the identifier is `keccak(provider\nparameters\ncontext)` and carries no nonce,
     *      so re-attesting the same identity reproduces an already-burned identifier. Consumers that
     *      maintain their own consumption mapping should call this and not `verifyProof`.
     */
    function checkProof(Proof memory proof) public view {
        // create signed claim using claimData and signature.
        require(proof.signedClaim.signatures.length > 0, "No signatures");
        Claims.SignedClaim memory signed = Claims.SignedClaim(proof.signedClaim.claim, proof.signedClaim.signatures);

        // check if the hash from the claimInfo is equal to the infoHash in the claimData
        bytes32 hashed = Claims.hashClaimInfo(proof.claimInfo);
        require(proof.signedClaim.claim.identifier == hashed, "Claim identifier mismatch");

        // fetch witness list from fetchEpoch(_epoch).witnesses
        Witness[] memory expectedWitnesses = fetchWitnessesForClaim(
            proof.signedClaim.claim.epoch, proof.signedClaim.claim.identifier, proof.signedClaim.claim.timestampS
        );
        address[] memory signedWitnesses = Claims.recoverSignersOfSignedClaim(signed);

        // check if the number of signatures is equal to the number of witnesses
        require(
            signedWitnesses.length == expectedWitnesses.length, "Number of signatures not equal to number of witnesses"
        );

        for (uint256 i = 0; i < signedWitnesses.length; i++) {
            for (uint256 j = 0; j < signedWitnesses.length; j++) {
                if (i == j) continue;
                require(signedWitnesses[i] != signedWitnesses[j], "Duplicated Signatures Found");
            }
        }

        // Update awaited: more checks on whose signatures can be considered.
        for (uint256 i = 0; i < signed.signatures.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < expectedWitnesses.length; j++) {
                if (signedWitnesses[i] == expectedWitnesses[j].addr) {
                    found = true;
                    break;
                }
            }
            require(found, "Signature not appropriate");
        }
    }

    /**
     * Call the function to assert
     * the validity of several claims proofs
     */
    function verifyProof(Proof memory proof) public {
        // check if the proof has already been used
        bytes32 proofIdentifier = proof.signedClaim.claim.identifier;
        require(!usedProofs[proofIdentifier], "Proof already used");

        checkProof(proof);

        // mark the proof as used
        usedProofs[proofIdentifier] = true;
        emit ProofUsed(proofIdentifier);
    }

    // admin functions ---

    /**
     * @dev Add a new epoch
     */
    function addNewEpoch(Witness[] calldata witnesses, uint8 requisiteWitnessesForClaimCreate) external onlyOwner {
        require(witnesses.length > 0, "No witnesses provided");
        require(
            requisiteWitnessesForClaimCreate > 0 && requisiteWitnessesForClaimCreate <= witnesses.length,
            "Invalid requisite witnesses count"
        );

        if (epochDurationS == 0) {
            epochDurationS = 1 days;
        }
        if (epochs.length > 0) {
            epochs[epochs.length - 1].timestampEnd = uint32(block.timestamp);
        }

        currentEpoch += 1;
        Epoch storage epoch = epochs.push();
        epoch.id = currentEpoch;
        epoch.timestampStart = uint32(block.timestamp);
        epoch.timestampEnd = uint32(block.timestamp + epochDurationS);
        epoch.minimumWitnessesForClaimCreation = requisiteWitnessesForClaimCreate;

        for (uint256 i = 0; i < witnesses.length; i++) {
            epoch.witnesses.push(witnesses[i]);
        }

        emit EpochAdded(epochs[epochs.length - 1]);
    }
}
