// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MomoCandieNFT is ERC721, EIP712, ReentrancyGuard, Ownable {
    uint256 public constant MINT_PRICE = 0.08 ether;
    uint256 public constant MAX_PER_WALLET = 5;

    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address to,uint256 unitId,uint8 glitchIntensity,bytes32 nonce)");

    uint256 public immutable maxSupply;
    address public signer;

    uint256[] private _supplyCaps;
    uint256[] public unitMinted;
    uint256 private _totalMinted;
    uint256 private _nextTokenId;

    mapping(address => uint256) public walletMinted;
    mapping(bytes32 => bool) public usedNonces;
    mapping(uint256 => uint8) public glitchIntensity;

    error InsufficientETH();
    error MaxSupplyReached();
    error WalletLimitReached();
    error InvalidUnit();
    error UnitCapReached();
    error NonceUsed();
    error GlitchOutOfBounds();
    error InvalidSigner();

    constructor(address _signer, uint256[] memory caps)
        ERC721("MomoCandieNFT", "MOMO")
        EIP712("MomoCandieNFT", "1")
        Ownable(msg.sender)
    {
        signer = _signer;
        _supplyCaps = caps;
        unitMinted = new uint256[](caps.length);

        uint256 total;
        for (uint256 i; i < caps.length; ++i) {
            total += caps[i];
        }
        maxSupply = total;
    }

    function totalMinted() external view returns (uint256) {
        return _totalMinted;
    }

    function supplyCaps(uint256 i) external view returns (uint256) {
        return _supplyCaps[i];
    }

    function supplyCapsLength() external view returns (uint256) {
        return _supplyCaps.length;
    }

    function mint(
        uint256 unitId,
        uint8 _glitchIntensity,
        bytes32 nonce,
        bytes calldata signature
    ) external payable nonReentrant {
        if (msg.value < MINT_PRICE) revert InsufficientETH();
        if (_totalMinted >= maxSupply) revert MaxSupplyReached();
        if (walletMinted[msg.sender] >= MAX_PER_WALLET) revert WalletLimitReached();
        if (unitId >= _supplyCaps.length) revert InvalidUnit();
        if (unitMinted[unitId] >= _supplyCaps[unitId]) revert UnitCapReached();
        if (usedNonces[nonce]) revert NonceUsed();
        if (_glitchIntensity > 100) revert GlitchOutOfBounds();

        _verifySignature(msg.sender, unitId, _glitchIntensity, nonce, signature);

        usedNonces[nonce] = true;
        unchecked {
            ++_totalMinted;
            ++walletMinted[msg.sender];
            ++unitMinted[unitId];
        }

        uint256 tokenId = _nextTokenId++;
        glitchIntensity[tokenId] = _glitchIntensity;
        _safeMint(msg.sender, tokenId);

        // Refund excess so invariant balance == totalMinted * MINT_PRICE holds
        uint256 excess = msg.value - MINT_PRICE;
        if (excess > 0) {
            payable(msg.sender).transfer(excess);
        }
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // Exposed for test-side signature construction
    function computeDigest(address to, uint256 unitId, uint8 _glitchIntensity, bytes32 nonce)
        external
        view
        returns (bytes32 structHash, bytes32 digest)
    {
        structHash = keccak256(abi.encode(MINT_TYPEHASH, to, unitId, _glitchIntensity, nonce));
        digest = _hashTypedDataV4(structHash);
    }

    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    function _verifySignature(
        address to,
        uint256 unitId,
        uint8 _glitchIntensity,
        bytes32 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 structHash =
            keccak256(abi.encode(MINT_TYPEHASH, to, unitId, _glitchIntensity, nonce));
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != signer) revert InvalidSigner();
    }
}
