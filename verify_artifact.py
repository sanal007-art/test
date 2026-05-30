import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

from web3 import Web3

CONTRACT_ADDRESS_FILE = "contract_address.json"
CONTRACT_ABI_FILE = "contract_abi.json"


def load_env_value(name, required=True):
    value = os.getenv(name)
    if required and not value:
        raise EnvironmentError(f"Missing required environment variable: {name}")
    return value


def compute_sha256(file_path):
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def load_contract_address(address_file=CONTRACT_ADDRESS_FILE):
    if not Path(address_file).exists():
        raise FileNotFoundError(f"Contract address file not found: {address_file}")
    data = json.loads(Path(address_file).read_text(encoding="utf-8"))
    return data.get("contract_address")


def load_contract_abi(abi_file=CONTRACT_ABI_FILE):
    if not Path(abi_file).exists():
        raise FileNotFoundError(f"Contract ABI file not found: {abi_file}")
    data = json.loads(Path(abi_file).read_text(encoding="utf-8"))
    return data.get("abi")


def get_contract(w3, abi, contract_address):
    return w3.eth.contract(address=contract_address, abi=abi)


def verify_artifact(contract, artifact_id, artifact_hash):
    is_valid = contract.functions.verifyArtifact(artifact_id, artifact_hash).call()
    record = contract.functions.getArtifact(artifact_id).call()
    return is_valid, record


def parse_args():
    parser = argparse.ArgumentParser(
        description="Verify artifact integrity against blockchain records before deployment."
    )
    parser.add_argument(
        "--artifact-path",
        required=True,
        help="Path to the artifact file to verify.",
    )
    parser.add_argument(
        "--artifact-id",
        required=True,
        help="Artifact ID stored on the blockchain.",
    )
    parser.add_argument(
        "--node-url",
        default=None,
        help="Ethereum node URL. Falls back to ETH_NODE_URL env var.",
    )
    parser.add_argument(
        "--contract-address",
        default=None,
        help="Explicit contract address. Falls back to contract_address.json.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()

    if not Path(args.artifact_path).exists():
        print(f"ERROR: Artifact file not found: {args.artifact_path}")
        sys.exit(1)

    node_url = args.node_url or os.getenv("ETH_NODE_URL", "http://127.0.0.1:7545")

    w3 = Web3(Web3.HTTPProvider(node_url))
    if not w3.is_connected():
        print(f"ERROR: Cannot connect to Ethereum node at {node_url}")
        sys.exit(1)

    contract_address = args.contract_address or load_contract_address()
    contract_abi = load_contract_abi()
    contract = get_contract(w3, contract_abi, contract_address)

    artifact_hash = compute_sha256(args.artifact_path)

    print("=" * 70)
    print("ARTIFACT VERIFICATION GATEWAY")
    print("=" * 70)
    print(f"\nArtifact path: {args.artifact_path}")
    print(f"Artifact ID: {args.artifact_id}")
    print(f"Computed SHA-256: {artifact_hash}")
    print(f"Contract address: {contract_address}")
    print()

    is_valid, record = verify_artifact(contract, args.artifact_id, artifact_hash)
    stored_id, stored_hash, timestamp, signer, stage = record

    print("Verification Result:")
    print("-" * 70)

    if is_valid:
        print("✓ VERIFICATION PASSED - Artifact integrity verified")
        print("\nStored record:")
        print(f"  artifact_id: {stored_id}")
        print(f"  stored_hash: {stored_hash}")
        print(f"  timestamp: {timestamp}")
        print(f"  signer: {signer}")
        print(f"  stage: {stage}")
        print("\n✓ DEPLOYMENT AUTHORIZED")
        print("=" * 70)
        sys.exit(0)
    else:
        print("✗ VERIFICATION FAILED - Artifact has been tampered with!")
        print("\nStored record:")
        print(f"  artifact_id: {stored_id}")
        print(f"  stored_hash: {stored_hash}")
        print(f"  timestamp: {timestamp}")
        print(f"  signer: {signer}")
        print(f"  stage: {stage}")
        print("\nComputed hash does NOT match stored hash.")
        print("✗ DEPLOYMENT BLOCKED - Do not proceed")
        print("=" * 70)
        sys.exit(1)
