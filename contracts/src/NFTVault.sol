// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "./utils/ERC721.sol";
import {Ownable} from "./utils/Ownable.sol";

/**
 * @title NFTVault
 * @notice Escrow for ERC721 NFTs on the EVM side of a cross-chain channel.
 *         ETH→SOL: lock NFT + emit receipt with metadata hash.
 *         SOL→ETH: unlock original NFT after wrapped NFT burned on Solana.
 *
 * Timelock: if not committed within deadline, original owner can reclaim NFT.
 */
contract NFTVault is Ownable {
    struct NFTLockRecord {
        address owner;
        address tokenContract;
        uint256 tokenId;
        bytes32 metadataHash;   // keccak256 of metadata JSON
        uint256 timeoutAt;
        bool    committed;
        bool    refunded;
    }

    address public relayer;
    mapping(bytes32 => NFTLockRecord) public locks;  // crossChainId => record

    event NFTLocked(
        address indexed owner,
        address indexed tokenContract,
        uint256 tokenId,
        bytes32 crossChainId,
        bytes32 nonceHash,
        bytes32 metadataHash,
        bytes   destWallet,
        uint256 timeoutAt
    );
    event NFTUnlocked(
        address indexed to,
        address indexed tokenContract,
        uint256 tokenId,
        bytes32 crossChainId
    );
    event NFTRefunded(bytes32 indexed crossChainId, address indexed owner);
    event RelayerUpdated(address oldRelayer, address newRelayer);

    error AlreadyLocked(bytes32 crossChainId);
    error NotLocked(bytes32 crossChainId);
    error AlreadyFinalized(bytes32 crossChainId);
    error NotTimedOut(bytes32 crossChainId);
    error NotRelayer(address caller);
    error ZeroAddress();

    modifier onlyRelayer() {
        if (msg.sender != relayer && msg.sender != owner) revert NotRelayer(msg.sender);
        _;
    }

    constructor(address _relayer) {
        if (_relayer == address(0)) revert ZeroAddress();
        relayer = _relayer;
    }

    // ── Lock NFT (ETH→SOL) ────────────────────────────────────────────────────

    /**
     * @notice Lock an ERC721 NFT to initiate ETH→SOL NFT transfer.
     * @param tokenContract  ERC721 contract address
     * @param tokenId        Token ID to lock
     * @param crossChainId   Hub-generated unique identifier
     * @param metadataHash   keccak256 of the NFT's metadata JSON (fetched off-chain before call)
     * @param destWallet     Destination Solana wallet (32-byte pubkey)
     * @param timeoutSec     Seconds until lock expires
     */
    function lockNFT(
        address tokenContract,
        uint256 tokenId,
        bytes32 crossChainId,
        bytes32 metadataHash,
        bytes calldata destWallet,
        uint256 timeoutSec
    ) external {
        if (tokenContract == address(0)) revert ZeroAddress();
        if (locks[crossChainId].owner != address(0)) revert AlreadyLocked(crossChainId);

        uint256 timeoutAt = block.timestamp + timeoutSec;
        bytes32 nonceHash = keccak256(abi.encodePacked(
            block.chainid, address(this), msg.sender, crossChainId
        ));

        locks[crossChainId] = NFTLockRecord({
            owner:         msg.sender,
            tokenContract: tokenContract,
            tokenId:       tokenId,
            metadataHash:  metadataHash,
            timeoutAt:     timeoutAt,
            committed:     false,
            refunded:      false
        });

        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);
        emit NFTLocked(msg.sender, tokenContract, tokenId, crossChainId,
                       nonceHash, metadataHash, destWallet, timeoutAt);
    }

    // ── Commit (relayer: destination wrapped NFT minted) ─────────────────────

    function commitNFT(bytes32 crossChainId) external onlyRelayer {
        NFTLockRecord storage rec = locks[crossChainId];
        if (rec.owner == address(0)) revert NotLocked(crossChainId);
        if (rec.committed || rec.refunded) revert AlreadyFinalized(crossChainId);
        rec.committed = true;
        // NFT stays in vault — it's now permanently escrowed unless reverse flow
    }

    // ── Unlock (SOL→ETH reverse: release original NFT) ───────────────────────

    /**
     * @notice Release original NFT back after wrapped NFT burned on Solana.
     *         Relayer calls this after verifying Solana burn (oracle sigs for POC).
     */
    function unlockNFT(
        address to,
        bytes32 crossChainId
    ) external onlyRelayer {
        if (to == address(0)) revert ZeroAddress();
        NFTLockRecord storage rec = locks[crossChainId];
        if (rec.owner == address(0)) revert NotLocked(crossChainId);
        if (rec.committed || rec.refunded) revert AlreadyFinalized(crossChainId);

        rec.committed = true;
        ERC721(rec.tokenContract).transferFrom(address(this), to, rec.tokenId);
        emit NFTUnlocked(to, rec.tokenContract, rec.tokenId, crossChainId);
    }

    // ── Timeout refund ────────────────────────────────────────────────────────

    function claimTimeout(bytes32 crossChainId) external {
        NFTLockRecord storage rec = locks[crossChainId];
        if (rec.owner == address(0)) revert NotLocked(crossChainId);
        if (rec.committed || rec.refunded) revert AlreadyFinalized(crossChainId);
        if (block.timestamp < rec.timeoutAt) revert NotTimedOut(crossChainId);

        rec.refunded = true;
        ERC721(rec.tokenContract).transferFrom(address(this), rec.owner, rec.tokenId);
        emit NFTRefunded(crossChainId, rec.owner);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setRelayer(address _relayer) external onlyOwner {
        if (_relayer == address(0)) revert ZeroAddress();
        emit RelayerUpdated(relayer, _relayer);
        relayer = _relayer;
    }
}
