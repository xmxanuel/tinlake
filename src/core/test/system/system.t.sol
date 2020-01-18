// Copyright (C) 2019 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "./test_utils.sol";

contract SystemTest is TestUtils, DSTest {
    // users
    AdminUser public  admin;
    address      admin_;
    User borrower;
    address      borrower_;
    // todo add investor

    // hevm
    Hevm public hevm;

    function setUp() public {
        // setup hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(1234567);

        // setup deployment

        deployContracts();

        // setup users
        borrower = new User(address(borrowerDeployer.shelf()), address(lenderDeployer.distributor()), currency_, address(borrowerDeployer.pile()));
        borrower_ = address(borrower);
        admin = new AdminUser();
        admin_ = address(admin);
        admin.file(borrowerDeployer);

        // give admin access rights to contract
        // root only for this test setup
        rootAdmin.relyBorrowAdmin(admin_);
    }

   // Checks
    function checkAfterBorrow(uint tokenId, uint tBalance) public {
        assertEq(currency.balanceOf(borrower_), tBalance);
        assertEq(collateralNFT.ownerOf(tokenId), address(borrowerDeployer.shelf()));
    }

    function checkAfterRepay(uint loan, uint tokenId, uint tTotal, uint tLender) public {
        assertEq(collateralNFT.ownerOf(tokenId), borrower_);
        assertEq(borrowerDeployer.pile().debt(loan), 0);
        assertEq(currency.balanceOf(borrower_), tTotal - tLender);
        assertEq(currency.balanceOf(address(borrowerDeployer.pile())), 0);
    }

    function whitelist(uint tokenId, address collateralNFT_, uint principal, address borrower_, uint rate) public returns (uint) {
        // define rate
        admin.doInitRate(rate, rate);
        // collateralNFT whitelist
        uint loan = admin.doAdmit(collateralNFT_, tokenId, principal, borrower_);

        // add rate for loan
        admin.doAddRate(loan, rate);
        return loan;
    }

    function borrow(uint loan, uint tokenId, uint principal) public {
        borrower.doApproveNFT(collateralNFT, address(borrowerDeployer.shelf()));

        // borrow transaction
        borrower.doBorrow(loan, principal);
        checkAfterBorrow(tokenId, principal);
    }

    function defaultLoan() public pure returns(uint principal, uint rate) {
        uint principal = 1000 ether;
        // define rate
        uint rate = uint(1000000564701133626865910626); // 5 % day

        return (principal, rate);
    }

    function setupOngoingLoan() public returns (uint loan, uint tokenId, uint principal, uint rate) {
        (uint principal, uint rate) = defaultLoan();
        // create borrower collateral collateralNFT
        uint tokenId = collateralNFT.issue(borrower_);
        uint loan = whitelist(tokenId, collateralNFT_, principal,borrower_, rate);
        borrow(loan, tokenId, principal);

        return (loan, tokenId, principal, rate);
    }

    function setupRepayReq() public returns(uint) {
        // borrower needs some currency to pay rate
        uint extra = 100000000000 ether;
        currency.mint(borrower_, extra);

        // allow pile full control over borrower tokens
        borrower.doApproveCurrency(address(borrowerDeployer.shelf()), uint(-1));

        return extra;
    }

    // note: this method will be refactored with the new lender side contracts, as the distributor should not hold any currency
    function currdistributorBal() public returns(uint) {
        return currency.balanceOf(address(lenderDeployer.distributor()));
    }

    function borrowRepay(uint principal, uint rate) public {
        ShelfLike shelf_ = ShelfLike(address(borrowerDeployer.shelf()));
        CeilingLike ceiling_ = CeilingLike(address(borrowerDeployer.principal()));

        // create borrower collateral collateralNFT
        uint tokenId = collateralNFT.issue(borrower_);
        uint loan = whitelist(tokenId, collateralNFT_, principal, borrower_, rate);

        assertEq(ceiling_.values(loan), principal);
        borrow(loan, tokenId, principal);


        assertEq(ceiling_.values(loan), 0);

        hevm.warp(now + 10 days);

        // borrower needs some currency to pay rate
        setupRepayReq();
        uint distributorShould = borrowerDeployer.pile().debt(loan) + currdistributorBal();

        // close without defined amount
        borrower.doClose(loan, borrower_);
        uint totalT = uint(currency.totalSupply());
        checkAfterRepay(loan, tokenId, totalT, distributorShould);
    }

    // --- Tests ---

    function testBorrowTransaction() public {
        // collateralNFT value
        uint principal = 100;

        // create borrower collateral collateralNFT
        uint tokenId = collateralNFT.issue(borrower_);
        uint loan = admin.doAdmit(collateralNFT_, tokenId, principal, borrower_);
        borrower.doApproveNFT(collateralNFT, address(borrowerDeployer.shelf()));
        borrower.doBorrow(loan, principal);

        checkAfterBorrow(tokenId, principal);
    }

    function testBorrowAndRepay() public {
        (uint principal, uint rate) = defaultLoan();
        borrowRepay(principal, rate);
    }


    function testMediumSizeLoans() public {
        (uint principal, uint rate) = defaultLoan();

        principal = 1000000 ether;

        borrowRepay(principal, rate);
    }

    function testHighSizeLoans() public {
        (uint principal, uint rate) = defaultLoan();
        principal = 100000000 ether; // 100 million

        borrowRepay(principal, rate);
    }

    function testRepayFullAmount() public {
        (uint loan, uint tokenId, uint principal, uint rate) = setupOngoingLoan();

        hevm.warp(now + 1 days);

        // borrower needs some currency to pay rate
        setupRepayReq();
        uint distributorShould = borrowerDeployer.pile().debt(loan) + currdistributorBal();

        // close without defined amount
        borrower.doClose(loan, borrower_);

        uint totalT = uint(currency.totalSupply());
        checkAfterRepay(loan, tokenId, totalT, distributorShould);
    }

    function testLongOngoing() public {
        (uint loan, uint tokenId, uint principal, uint rate) = setupOngoingLoan();

        // interest 5% per day 1.05^300 ~ 2273996.1286 chi
        hevm.warp(now + 300 days);

        // borrower needs some currency to pay rate
        setupRepayReq();

        uint distributorShould = borrowerDeployer.pile().debt(loan) + currdistributorBal();

        // close without defined amount
        borrower.doClose(loan, borrower_);

        uint totalT = uint(currency.totalSupply());
        checkAfterRepay(loan, tokenId, totalT, distributorShould);
    }

    function testMultipleBorrowAndRepay () public {
        uint principal = 100;
        uint rate = uint(1000000564701133626865910626);

        uint tBorrower = 0;
        // borrow
        for (uint i = 1; i <= 10; i++) {

            principal = i * 80;

            // create borrower collateral collateralNFT
            uint tokenId = collateralNFT.issue(borrower_);
            uint loan = whitelist(tokenId, collateralNFT_, principal, borrower_, rate);
            // collateralNFT whitelist

            borrower.doApproveNFT(collateralNFT, address(borrowerDeployer.shelf()));
            borrower.doBorrow(loan, principal);
            tBorrower += principal;
            emit log_named_uint("total", tBorrower);
            checkAfterBorrow(i, tBorrower);
        }

        // repay
        uint tTotal = currency.totalSupply();

        // allow pile full control over borrower tokens
        borrower.doApproveCurrency(address(borrowerDeployer.shelf()), uint(-1));

        uint distributorBalance = currency.balanceOf(address(lenderDeployer.distributor()));
        for (uint i = 1; i <= 10; i++) {
            principal = i * 80;

            // repay transaction
            emit log_named_uint("repay", principal);
            borrower.doRepay(i, principal, borrower_);

            distributorBalance += principal;
            checkAfterRepay(i, i, tTotal, distributorBalance);
        }
    }

    function testFailBorrowSameTokenIdTwice() public {
        // collateralNFT value
        uint principal = 100;

        // create borrower collateral collateralNFT
        uint tokenId = collateralNFT.issue(borrower_);
        uint loan = admin.doAdmit(collateralNFT_, tokenId, principal, borrower_);
        borrower.doApproveNFT(collateralNFT, address(borrowerDeployer.shelf()));
        borrower.doBorrow(loan, principal);
        checkAfterBorrow(tokenId, principal);

        // should fail
        borrower.doBorrow(loan, principal);
    }

    function testFailBorrowNonExistingToken() public {
        borrower.doBorrow(42, 100);
        assertEq(currency.balanceOf(borrower_), 0);
    }

    function testFailBorrowNotWhitelisted() public {
        collateralNFT.issue(borrower_);
        borrower.doBorrow(1, 100);
        assertEq(currency.balanceOf(borrower_), 0);
    }

    function testFailAdmitNonExistingcollateralNFT() public {
        uint loan = admin.doAdmit(collateralNFT_, 1, 100, borrower_);
        borrower.doBorrow(loan, 100);
        assertEq(currency.balanceOf(borrower_), 0);
    }

    function testFailBorrowcollateralNFTNotApproved() public {
        uint tokenId = collateralNFT.issue(borrower_);
        uint loan = admin.doAdmit(collateralNFT_, tokenId, 100, borrower_);
        borrower.doBorrow(loan, 100);
        assertEq(currency.balanceOf(borrower_), 100);
    }
}