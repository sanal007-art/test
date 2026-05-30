// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract ArtifactIntegrity {
    struct ArtifactRecord {
        string artifactId;
        string artifactHash;
        uint256 timestamp;
        string signer;
        string stage;
    }

    mapping(string => ArtifactRecord) private records;

    event ArtifactStored(
        string indexed artifactId,
        string artifactHash,
        uint256 timestamp,
        string signer,
        string stage
    );

    function storeArtifact(
        string memory artifactId,
        string memory artifactHash,
        string memory signer,
        string memory stage
    ) public {
        records[artifactId] = ArtifactRecord(
            artifactId,
            artifactHash,
            block.timestamp,
            signer,
            stage
        );

        emit ArtifactStored(artifactId, artifactHash, block.timestamp, signer, stage);
    }

    function getArtifact(string memory artifactId)
        public
        view
        returns (
            string memory,
            string memory,
            uint256,
            string memory,
            string memory
        )
    {
        ArtifactRecord memory record = records[artifactId];
        return (
            record.artifactId,
            record.artifactHash,
            record.timestamp,
            record.signer,
            record.stage
        );
    }

    function verifyArtifact(string memory artifactId, string memory artifactHash)
        public
        view
        returns (bool)
    {
        ArtifactRecord memory record = records[artifactId];
        return keccak256(bytes(record.artifactHash)) == keccak256(bytes(artifactHash));
    }
}