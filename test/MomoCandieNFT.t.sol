// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../src/MomoCandieNFT.sol";

// ─── Reentrancy attack helper ──────────────────────────────────────────────

contract ReentrantMinter is IERC721Receiver {
    MomoCandieNFT internal immutable nft;
    bytes32 internal attackNonce;
    bytes internal attackSig;
    bytes32 internal reentrantNonce;
    bytes internal reentrantSig;
    bool internal entered;

    constructor(MomoCandieNFT _nft) {
        nft = _nft;
    }

    function setup(
        bytes32 _attackNonce,
        bytes calldata _attackSig,
        bytes32 _reentrantNonce,
        bytes calldata _reentrantSig
    ) external {
        attackNonce = _attackNonce;
        attackSig = _attackSig;
        reentrantNonce = _reentrantNonce;
        reentrantSig = _reentrantSig;
    }

    function attack(uint256 price) external {
        nft.mint{value: price}(0, 50, attackNonce, attackSig);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        if (!entered) {
            entered = true;
            uint256 price = nft.MINT_PRICE();
            // Attempt re-entry — ReentrancyGuard should reject this and propagate
            nft.mint{value: price}(0, 50, reentrantNonce, reentrantSig);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

// ─── Unit + Fuzz tests ────────────────────────────────────────────────────

contract MomoCandieNFTTest is Test {
    MomoCandieNFT internal nft;

    uint256 internal constant SIGNER_KEY = 0xA11CE;
    address internal signer;
    address internal user = address(0x1234);
    uint256 internal mintPrice; // cached to avoid ordering issues with vm.expectRevert

    function setUp() public {
        signer = vm.addr(SIGNER_KEY);

        uint256[] memory caps = new uint256[](4);
        caps[0] = 2500;
        caps[1] = 2500;
        caps[2] = 2500;
        caps[3] = 2500;

        nft = new MomoCandieNFT(signer, caps);
        mintPrice = nft.MINT_PRICE();
        vm.deal(user, 100 ether);
    }

    // ── EIP-712 helpers ──────────────────────────────────────────────────
    // Use the contract's own computeDigest so the signed digest is guaranteed
    // to match what _verifySignature reconstructs internally.

    function _sign(address to, uint256 unitId, uint8 glitch, bytes32 nonce)
        internal
        view
        returns (bytes memory)
    {
        return _signFor(nft, to, unitId, glitch, nonce);
    }

    function _signFor(
        MomoCandieNFT target,
        address to,
        uint256 unitId,
        uint8 glitch,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        (, bytes32 digest) = target.computeDigest(to, unitId, glitch, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── EIP-712 domain separator consistency ────────────────────────────

    function test_domainSeparator_consistentWithComputeDigest() public view {
        bytes32 nonce = keccak256("ds_test");
        bytes32 structHash =
            keccak256(abi.encode(nft.MINT_TYPEHASH(), user, uint256(0), uint8(50), nonce));
        bytes32 expected =
            keccak256(abi.encodePacked("\x19\x01", nft.DOMAIN_SEPARATOR(), structHash));
        (, bytes32 actual) = nft.computeDigest(user, 0, 50, nonce);
        assertEq(expected, actual);
    }

    // ── Deployment tests ─────────────────────────────────────────────────

    function test_deployment_name() public view {
        assertEq(nft.name(), "MomoCandieNFT");
    }

    function test_deployment_symbol() public view {
        assertEq(nft.symbol(), "MOMO");
    }

    function test_deployment_maxSupply() public view {
        assertEq(nft.maxSupply(), 10_000);
    }

    function test_deployment_supplyCaps() public view {
        assertEq(nft.supplyCaps(0), 2500);
        assertEq(nft.supplyCaps(1), 2500);
        assertEq(nft.supplyCaps(2), 2500);
        assertEq(nft.supplyCaps(3), 2500);
    }

    function test_deployment_totalSupplySums() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += nft.supplyCaps(i);
        }
        assertEq(sum, nft.maxSupply());
    }

    // ── Mint happy-path tests ─────────────────────────────────────────────

    function test_mint_succeeds() public {
        bytes32 nonce = keccak256("nonce1");
        bytes memory sig = _sign(user, 0, 50, nonce);

        vm.prank(user);
        nft.mint{value: mintPrice}(0, 50, nonce, sig);

        assertEq(nft.balanceOf(user), 1);
        assertEq(nft.ownerOf(0), user);
        assertEq(nft.glitchIntensity(0), 50);
    }

    function test_mint_incrementsTotalMinted() public {
        bytes32 nonce = keccak256("nonce_total");
        bytes memory sig = _sign(user, 0, 50, nonce);

        vm.prank(user);
        nft.mint{value: mintPrice}(0, 50, nonce, sig);

        assertEq(nft.totalMinted(), 1);
        assertEq(nft.unitMinted(0), 1);
        assertEq(nft.walletMinted(user), 1);
    }

    function test_mint_refundsExcess() public {
        bytes32 nonce = keccak256("nonce_excess");
        bytes memory sig = _sign(user, 0, 50, nonce);

        uint256 balBefore = user.balance;
        vm.prank(user);
        nft.mint{value: 1 ether}(0, 50, nonce, sig); // overpay by 0.92 ether

        assertEq(address(nft).balance, mintPrice);
        assertEq(user.balance, balBefore - mintPrice);
    }

    function test_mint_revertsMaxSupplyReached() public {
        uint256[] memory tinyCaps = new uint256[](1);
        tinyCaps[0] = 1;
        MomoCandieNFT tiny = new MomoCandieNFT(signer, tinyCaps);

        address minter = address(0xABC);
        vm.deal(minter, 10 ether);

        bytes32 n1 = keccak256("tiny1");
        bytes memory sig1 = _signFor(tiny, minter, 0, 50, n1);
        vm.prank(minter);
        tiny.mint{value: mintPrice}(0, 50, n1, sig1);

        bytes32 n2 = keccak256("tiny2");
        bytes memory sig2 = _signFor(tiny, minter, 0, 50, n2);
        vm.prank(minter);
        vm.expectRevert(MomoCandieNFT.MaxSupplyReached.selector);
        tiny.mint{value: mintPrice}(0, 50, n2, sig2);
    }

    function test_mint_revertsInvalidUnit() public {
        bytes32 nonce = keccak256("invalid_unit");
        bytes memory sig = _sign(user, 99, 50, nonce);

        vm.prank(user);
        vm.expectRevert(MomoCandieNFT.InvalidUnit.selector);
        nft.mint{value: mintPrice}(99, 50, nonce, sig);
    }

    // ── Reentrancy test ──────────────────────────────────────────────────

    function test_reentrancyGuard_blocksReentry() public {
        ReentrantMinter attacker = new ReentrantMinter(nft);
        vm.deal(address(attacker), 10 ether);

        bytes32 n1 = keccak256("reentrant1");
        bytes32 n2 = keccak256("reentrant2");
        bytes memory s1 = _sign(address(attacker), 0, 50, n1);
        bytes memory s2 = _sign(address(attacker), 0, 50, n2);
        attacker.setup(n1, s1, n2, s2);

        vm.expectRevert();
        attacker.attack(mintPrice);

        // Nothing was minted — state was rolled back
        assertEq(nft.totalMinted(), 0);
    }

    // ── Withdraw tests ───────────────────────────────────────────────────

    function test_withdraw_sendsBalance() public {
        bytes32 nonce = keccak256("wd_nonce");
        bytes memory sig = _sign(user, 0, 50, nonce);
        vm.prank(user);
        nft.mint{value: mintPrice}(0, 50, nonce, sig);

        uint256 before = address(this).balance;
        nft.withdraw();
        assertEq(address(nft).balance, 0);
        assertEq(address(this).balance, before + mintPrice);
    }

    function test_withdraw_revertsIfNotOwner() public {
        vm.prank(user);
        vm.expectRevert();
        nft.withdraw();
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────

    function testFuzz_mint_insufficientEth(uint96 value) public {
        vm.assume(uint256(value) < mintPrice);
        bytes32 nonce = keccak256(abi.encodePacked("insuf", value));
        bytes memory sig = _sign(user, 0, 50, nonce);

        vm.prank(user);
        vm.expectRevert(MomoCandieNFT.InsufficientETH.selector);
        nft.mint{value: value}(0, 50, nonce, sig);
    }

    function testFuzz_mint_sufficientEth(uint96 value) public {
        vm.assume(uint256(value) >= mintPrice);
        vm.deal(user, value);
        bytes32 nonce = keccak256(abi.encodePacked("suf", value));
        bytes memory sig = _sign(user, 0, 50, nonce);

        vm.prank(user);
        nft.mint{value: value}(0, 50, nonce, sig);

        assertEq(nft.totalMinted(), 1);
        assertEq(address(nft).balance, mintPrice);
    }

    function testFuzz_mint_invalidSignerAlwaysReverts(uint256 badKey) public {
        uint256 secp256k1Order =
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        vm.assume(badKey != 0 && badKey != SIGNER_KEY && badKey < secp256k1Order);

        bytes32 nonce = keccak256("bad_key");
        // Compute the correct digest (same as contract will verify against)
        (, bytes32 digest) = nft.computeDigest(user, 0, 50, nonce);
        // Sign with the WRONG key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(user);
        vm.expectRevert(MomoCandieNFT.InvalidSigner.selector);
        nft.mint{value: mintPrice}(0, 50, nonce, sig);
    }

    function testFuzz_walletLimit(uint8 count) public {
        uint256 maxPerWallet = nft.MAX_PER_WALLET(); // cache — external call must not be inside the prank window
        count = uint8(bound(count, 1, maxPerWallet + 1));

        for (uint256 i; i < count; ++i) {
            bytes32 nonce = keccak256(abi.encodePacked("wl", i));
            bytes memory sig = _sign(user, 0, 50, nonce);
            vm.prank(user);
            if (i < maxPerWallet) {
                nft.mint{value: mintPrice}(0, 50, nonce, sig);
            } else {
                vm.expectRevert(MomoCandieNFT.WalletLimitReached.selector);
                nft.mint{value: mintPrice}(0, 50, nonce, sig);
                return;
            }
        }
    }

    function testFuzz_unitCapNeverExceeded(uint8 extra) public {
        extra = uint8(bound(extra, 1, 5));

        uint256[] memory tinyCaps = new uint256[](2);
        tinyCaps[0] = 1;
        tinyCaps[1] = 100;
        MomoCandieNFT tiny = new MomoCandieNFT(signer, tinyCaps);

        address minter = address(0xBEEF);
        vm.deal(minter, 100 ether);

        // Exhaust unit 0
        bytes32 n0 = keccak256("uce_n0");
        bytes memory sig0 = _signFor(tiny, minter, 0, 50, n0);
        vm.prank(minter);
        tiny.mint{value: mintPrice}(0, 50, n0, sig0);

        // Every additional attempt to unit 0 must revert
        for (uint256 i; i < extra; ++i) {
            bytes32 nonce = keccak256(abi.encodePacked("uce_extra", i));
            bytes memory sig = _signFor(tiny, minter, 0, 50, nonce);
            vm.prank(minter);
            vm.expectRevert(MomoCandieNFT.UnitCapReached.selector);
            tiny.mint{value: mintPrice}(0, 50, nonce, sig);
        }

        assertEq(tiny.unitMinted(0), 1);
    }

    function testFuzz_nonceReplayReverts(uint8 seed) public {
        seed = uint8(bound(seed, 0, 20));
        bytes32 nonce = keccak256(abi.encodePacked("replay", seed));
        bytes memory sig = _sign(user, 0, 50, nonce);

        vm.prank(user);
        nft.mint{value: mintPrice}(0, 50, nonce, sig);

        address user2 = address(0x9999);
        vm.deal(user2, 10 ether);
        bytes memory sig2 = _sign(user2, 0, 50, nonce);
        vm.prank(user2);
        vm.expectRevert(MomoCandieNFT.NonceUsed.selector);
        nft.mint{value: mintPrice}(0, 50, nonce, sig2);
    }

    function testFuzz_glitchIntensityBounds(uint8 intensity) public {
        bytes32 nonce = keccak256(abi.encodePacked("glitch", intensity));
        bytes memory sig = _sign(user, 0, intensity, nonce);

        vm.prank(user);
        if (intensity <= 100) {
            nft.mint{value: mintPrice}(0, intensity, nonce, sig);
            assertEq(nft.glitchIntensity(0), intensity);
        } else {
            vm.expectRevert(MomoCandieNFT.GlitchOutOfBounds.selector);
            nft.mint{value: mintPrice}(0, intensity, nonce, sig);
        }
    }

    receive() external payable {}
}

// ─── Invariant handler ────────────────────────────────────────────────────

contract MintHandler {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MomoCandieNFT public immutable nft;
    uint256 public immutable signerKey;
    uint256 private _nonceSeed;

    address[3] public actors = [address(0x10), address(0x20), address(0x30)];

    constructor(MomoCandieNFT _nft, uint256 _signerKey) {
        nft = _nft;
        signerKey = _signerKey;
        uint256 price = _nft.MINT_PRICE();
        for (uint256 i; i < 3; ++i) {
            vm.deal(actors[i], 1_000 ether + price);
        }
    }

    function mint(uint8 actorSeed, uint8 unitSeed, uint8 glitchSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 unitId = unitSeed % nft.supplyCapsLength();
        uint8 glitch = uint8(uint256(glitchSeed) % 101);

        bytes32 nonce = keccak256(abi.encodePacked(_nonceSeed++, actor));
        (, bytes32 digest) = nft.computeDigest(actor, unitId, glitch, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 price = nft.MINT_PRICE();
        vm.prank(actor);
        try nft.mint{value: price}(unitId, glitch, nonce, sig) {} catch {}
    }
}

// ─── Invariant tests ──────────────────────────────────────────────────────

contract MomoCandieNFTInvariantTest is Test {
    MomoCandieNFT public nft;
    MintHandler public handler;

    uint256 internal constant SIGNER_KEY = 0xA11CE;

    function setUp() public {
        uint256[] memory caps = new uint256[](4);
        caps[0] = 2500;
        caps[1] = 2500;
        caps[2] = 2500;
        caps[3] = 2500;

        nft = new MomoCandieNFT(vm.addr(SIGNER_KEY), caps);
        handler = new MintHandler(nft, SIGNER_KEY);
        targetContract(address(handler));
    }

    function invariant_totalMintedNeverExceedsMaxSupply() public view {
        assertLe(nft.totalMinted(), nft.maxSupply());
    }

    function invariant_unitCountNeverExceedsCap() public view {
        for (uint256 i; i < 4; ++i) {
            assertLe(nft.unitMinted(i), nft.supplyCaps(i));
        }
    }

    function invariant_ethBalanceMatchesMints() public view {
        assertEq(address(nft).balance, nft.totalMinted() * nft.MINT_PRICE());
    }
}
