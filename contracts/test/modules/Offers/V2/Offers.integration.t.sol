// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.10;

import {DSTest} from "ds-test/test.sol";

import {OffersV2} from "../../../../modules/Offers/V2/OffersV2.sol";
import {Zorb} from "../../../utils/users/Zorb.sol";
import {ZoraRegistrar} from "../../../utils/users/ZoraRegistrar.sol";
import {ZoraModuleManager} from "../../../../ZoraModuleManager.sol";
import {ZoraProtocolFeeSettings} from "../../../../auxiliary/ZoraProtocolFeeSettings/ZoraProtocolFeeSettings.sol";
import {ERC20TransferHelper} from "../../../../transferHelpers/ERC20TransferHelper.sol";
import {ERC721TransferHelper} from "../../../../transferHelpers/ERC721TransferHelper.sol";
import {RoyaltyEngine} from "../../../utils/modules/RoyaltyEngine.sol";

import {TestERC721} from "../../../utils/tokens/TestERC721.sol";
import {WETH} from "../../../utils/tokens/WETH.sol";
import {VM} from "../../../utils/VM.sol";

/// @title OffersV2IntegrationTest
/// @notice Integration Tests for Offers v2.0
contract OffersV2IntegrationTest is DSTest {
    VM internal vm;

    ZoraRegistrar internal registrar;
    ZoraProtocolFeeSettings internal ZPFS;
    ZoraModuleManager internal ZMM;
    ERC20TransferHelper internal erc20TransferHelper;
    ERC721TransferHelper internal erc721TransferHelper;
    RoyaltyEngine internal royaltyEngine;

    OffersV2 internal offers;
    TestERC721 internal token;
    WETH internal weth;

    Zorb internal seller;
    Zorb internal seller2;
    Zorb internal buyer;
    Zorb internal finder;
    Zorb internal royaltyRecipient;

    function setUp() public {
        // Cheatcodes
        vm = VM(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        // Deploy V3
        registrar = new ZoraRegistrar();
        ZPFS = new ZoraProtocolFeeSettings();
        ZMM = new ZoraModuleManager(address(registrar), address(ZPFS));
        erc20TransferHelper = new ERC20TransferHelper(address(ZMM));
        erc721TransferHelper = new ERC721TransferHelper(address(ZMM));

        // Init V3
        registrar.init(ZMM);
        ZPFS.init(address(ZMM), address(0));

        // Create users
        seller = new Zorb(address(ZMM));
        seller2 = new Zorb(address(ZMM));
        buyer = new Zorb(address(ZMM));
        finder = new Zorb(address(ZMM));
        royaltyRecipient = new Zorb(address(ZMM));

        // Deploy mocks
        royaltyEngine = new RoyaltyEngine(address(royaltyRecipient));
        token = new TestERC721();
        weth = new WETH();

        // Deploy Offers v2.0
        offers = new OffersV2(address(erc20TransferHelper), address(erc721TransferHelper), address(royaltyEngine), address(ZPFS), address(weth));
        registrar.registerModule(address(offers));

        // Set buyer balance
        vm.deal(address(buyer), 100 ether);

        // Mint buyer token
        token.mint(address(seller), 0);
        token.mint(address(seller2), 1);

        // Seller swap 50 ETH <> 50 WETH
        vm.prank(address(buyer));
        weth.deposit{value: 50 ether}();

        // Users approve Offers module
        seller.setApprovalForModule(address(offers), true);
        seller2.setApprovalForModule(address(offers), true);
        buyer.setApprovalForModule(address(offers), true);

        // Buyer approve ERC20TransferHelper
        vm.prank(address(buyer));
        weth.approve(address(erc20TransferHelper), 50 ether);

        // Seller approve ERC721TransferHelper
        vm.prank(address(seller));
        token.setApprovalForAll(address(erc721TransferHelper), true);

        vm.prank(address(seller2));
        token.setApprovalForAll(address(erc721TransferHelper), true);
    }

    /// ------------ ETH Offer ------------ ///

    function runETH() public {
        vm.startPrank(address(buyer));
        uint256 id = offers.createCollectionOffer{value: 1 ether}(address(token), address(0), 1 ether, 1000);
        uint256 id2 = offers.createCollectionOffer{value: 2 ether}(address(token), address(0), 2 ether, 1000);
        vm.stopPrank();

        vm.prank(address(seller));
        offers.fillCollectionOffer(address(token), 0, id, address(0), 1 ether, address(finder));

        vm.prank(address(seller2));
        offers.fillCollectionOffer(address(token), 1, id2, address(0), 2 ether, address(finder));
    }

    function test_ETHIntegration() public {
        uint256 beforeSellerBalance = address(seller).balance;
        uint256 beforeSeller2Balance = address(seller2).balance;
        uint256 beforeBuyerBalance = address(buyer).balance;
        uint256 beforeRoyaltyRecipientBalance = address(royaltyRecipient).balance;
        uint256 beforeFinderBalance = address(finder).balance;

        address beforeToken0Owner = token.ownerOf(0);
        address beforeToken1Owner = token.ownerOf(1);

        runETH();

        uint256 afterSellerBalance = address(seller).balance;
        uint256 afterSeller2Balance = address(seller2).balance;
        uint256 afterBuyerBalance = address(buyer).balance;
        uint256 afterRoyaltyRecipientBalance = address(royaltyRecipient).balance;
        uint256 afterFinderBalance = address(finder).balance;
        address afterToken0Owner = token.ownerOf(0);
        address afterToken1Owner = token.ownerOf(1);

        // 3 ETH withdrawn from buyer
        require((beforeBuyerBalance - afterBuyerBalance) == 3 ether);
        // 0.1 ETH creator royalty
        require((afterRoyaltyRecipientBalance - beforeRoyaltyRecipientBalance) == 0.1 ether);
        // 1000 bps finders fee (Remaining 0.95 ETH * 10% finders fee = 0.095 ETH)
        require((afterFinderBalance - beforeFinderBalance) == 0.29 ether);
        // Remaining 0.855 ETH paid to seller
        require((afterSellerBalance - beforeSellerBalance) == 0.855 ether);
        // Remaining 1.755 ETH paid to seller2
        require((afterSeller2Balance - beforeSeller2Balance) == 1.755 ether);
        // NFT transferred to seller
        require((beforeToken0Owner == address(seller)) && afterToken0Owner == address(buyer));
        require((beforeToken1Owner == address(seller2)) && afterToken1Owner == address(buyer));
    }

    // /// ------------ ERC-20 Offer ------------ ///

    function runERC20() public {
        vm.startPrank(address(buyer));
        uint256 id = offers.createCollectionOffer{value: 1 ether}(address(token), address(weth), 1 ether, 1000);
        uint256 id2 = offers.createCollectionOffer{value: 2 ether}(address(token), address(weth), 2 ether, 1000);
        vm.stopPrank();

        vm.prank(address(seller));
        offers.fillCollectionOffer(address(token), 0, id, address(weth), 1 ether, address(finder));

        vm.prank(address(seller2));
        offers.fillCollectionOffer(address(token), 1, id2, address(weth), 2 ether, address(finder));
    }

    function test_ERC20Integration() public {
        uint256 beforeSellerBalance = weth.balanceOf(address(seller));
        uint256 beforeSeller2Balance = weth.balanceOf(address(seller2));
        uint256 beforeBuyerBalance = weth.balanceOf(address(buyer));
        uint256 beforeRoyaltyRecipientBalance = weth.balanceOf(address(royaltyRecipient));
        uint256 beforeFinderBalance = weth.balanceOf(address(finder));

        address beforeToken0Owner = token.ownerOf(0);
        address beforeToken1Owner = token.ownerOf(1);

        runERC20();

        uint256 afterSellerBalance = weth.balanceOf(address(seller));
        uint256 afterSeller2Balance = weth.balanceOf(address(seller2));
        uint256 afterBuyerBalance = weth.balanceOf(address(buyer));
        uint256 afterRoyaltyRecipientBalance = weth.balanceOf(address(royaltyRecipient));
        uint256 afterFinderBalance = weth.balanceOf(address(finder));
        address afterToken0Owner = token.ownerOf(0);
        address afterToken1Owner = token.ownerOf(1);

        // 3 WETH withdrawn from buyer
        require((beforeBuyerBalance - afterBuyerBalance) == 3 ether);
        // 0.1 WETH creator royalty
        require((afterRoyaltyRecipientBalance - beforeRoyaltyRecipientBalance) == 0.1 ether);
        // 1000 bps finders fee (Remaining 0.95 WETH * 10% finders fee = 0.095 WETH)
        require((afterFinderBalance - beforeFinderBalance) == 0.29 ether);
        // Remaining 0.855 WETH paid to seller
        require((afterSellerBalance - beforeSellerBalance) == 0.855 ether);
        // Remaining 1.755 WETH paid to seller2
        require((afterSeller2Balance - beforeSeller2Balance) == 1.755 ether);
        // NFT transferred to seller
        require((beforeToken0Owner == address(seller)) && afterToken0Owner == address(buyer));
        require((beforeToken1Owner == address(seller2)) && afterToken1Owner == address(buyer));
    }
}
