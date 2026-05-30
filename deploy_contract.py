import argparse
import hashlib
import json
import os
from pathlib import Path

from solcx import compile_source, install_solc
from web3 import Web3

SOLC_VERSION = "0.8.17"
CONTRACT_FILE = "ArtifactIntegrity.sol"
CONTRACT_ADDRESS_FILE = "contract_address.json"


def install_compiler():
    install_solc(SOLC_VERSION)


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


def compile_contract(source_path):
    with open(source_path, "r", encoding="utf-8") as f:
        source = f.read()

    compiled = compile_source(source, solc_version=SOLC_VERSION)
    _, contract_interface = compiled.popitem()
    return contract_interface["abi"], contract_interface["bin"]


def save_contract_address(address, address_file=CONTRACT_ADDRESS_FILE):
    data = {"contract_address": address}
    Path(address_file).write_text(json.dumps(data), encoding="utf-8")


def save_contract_abi(abi, abi_file="contract_abi.json"):
    data = {"abi": abi}
    Path(abi_file).write_text(json.dumps(data, indent=2), encoding="utf-8")


def load_contract_address(address_file=CONTRACT_ADDRESS_FILE):
    if not Path(address_file).exists():
        return None
    data = json.loads(Path(address_file).read_text(encoding="utf-8"))
    return data.get("contract_address")


def deploy_contract(w3, account_address, private_key, abi, bytecode):
    contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    nonce = w3.eth.get_transaction_count(account_address)

    transaction = contract.constructor().build_transaction({
        "from": account_address,
        "nonce": nonce,
        "gas": 3000000,
        "gasPrice": w3.to_wei("20", "gwei"),
        "chainId": w3.eth.chain_id,
    })

    signed_tx = w3.eth.account.sign_transaction(transaction, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)

    print("Deploying contract...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    return receipt.contractAddress


def get_contract(w3, abi, contract_address):
    return w3.eth.contract(address=contract_address, abi=abi)


def store_artifact_record(
    w3,
    contract,
    account_address,
    private_key,
    artifact_id,
    artifact_hash,
    signer,
    stage,
):
    nonce = w3.eth.get_transaction_count(account_address)
    transaction = contract.functions.storeArtifact(
        artifact_id,
        artifact_hash,
        signer,
        stage,
    ).build_transaction({
        "from": account_address,
        "nonce": nonce,
        "gas": 3000000,
        "gasPrice": w3.to_wei("20", "gwei"),
        "chainId": w3.eth.chain_id,
    })

    signed_tx = w3.eth.account.sign_transaction(transaction, private_key)
    tx_hash = w3.eth.send_raw_transaction(signed_tx.raw_transaction)

    print(f"Storing artifact record for '{artifact_id}'...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)

    return receipt


def verify_artifact_record(contract, artifact_id, artifact_hash):
    is_valid = contract.functions.verifyArtifact(artifact_id, artifact_hash).call()
    record = contract.functions.getArtifact(artifact_id).call()
    return is_valid, record


def parse_args():
    parser = argparse.ArgumentParser(
        description="Deploy or update artifact integrity records on Ethereum."
    )
    parser.add_argument(
        "--artifact-path",
        required=True,
        help="Path to the artifact file to hash and store.",
    )
    parser.add_argument(
        "--artifact-id",
        required=True,
        help="Unique ID for the artifact in the blockchain record.",
    )
    parser.add_argument(
        "--signer",
        default="pipeline",
        help="Signer or pipeline identity associated with the artifact.",
    )
    parser.add_argument(
        "--stage",
        default="build",
        help="Pipeline stage for this artifact record.",
    )
    parser.add_argument(
        "--node-url",
        default=None,
        help="Ethereum node URL. Falls back to ETH_NODE_URL env var.",
    )
    parser.add_argument(
        "--contract-address",
        default=None,
        help="Use an existing contract address instead of deploying a new one.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()

    node_url = args.node_url or os.getenv("ETH_NODE_URL", "http://127.0.0.1:7545")
    account_address = load_env_value("ETH_ACCOUNT_ADDRESS")
    private_key = load_env_value("ETH_PRIVATE_KEY")

    install_compiler()
    abi, bytecode = compile_contract(CONTRACT_FILE)

    w3 = Web3(Web3.HTTPProvider(node_url))
    if not w3.is_connected():
        raise ConnectionError(f"Cannot connect to Ethereum node at {node_url}")

    contract_address = args.contract_address or load_contract_address()
    if contract_address:
        print(f"Using existing contract at {contract_address}")
        save_contract_abi(abi)
    else:
        contract_address = deploy_contract(w3, account_address, private_key, abi, bytecode)
        save_contract_address(contract_address)
        save_contract_abi(abi)
        print(f"Deployed contract at {contract_address}")

    contract = get_contract(w3, abi, contract_address)
    artifact_hash = compute_sha256(args.artifact_path)

    print(f"Artifact path: {args.artifact_path}")
    print(f"Artifact ID: {args.artifact_id}")
    print(f"Artifact SHA-256: {artifact_hash}")

    receipt = store_artifact_record(
        w3,
        contract,
        account_address,
        private_key,
        args.artifact_id,
        artifact_hash,
        args.signer,
        args.stage,
    )
    print(f"Artifact stored in tx: {receipt.transactionHash.hex()}")

    is_valid, record = verify_artifact_record(contract, args.artifact_id, artifact_hash)
    artifact_id, stored_hash, timestamp, signer, stage = record

    print("Verification result:", is_valid)
    print("Stored record:")
    print(f"  artifact_id: {artifact_id}")
    print(f"  artifact_hash: {stored_hash}")
    print(f"  timestamp: {timestamp}")
    print(f"  signer: {signer}")
    print(f"  stage: {stage}")
