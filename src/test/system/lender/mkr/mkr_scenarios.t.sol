// Copyright (C) 2020 Centrifuge

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

pragma solidity >=0.5.15 <0.6.0;
pragma experimental ABIEncoderV2;

import "../../test_suite.sol";
import "tinlake-math/interest.sol";
import {BaseTypes} from "../../../../lender/test/coordinator-base.t.sol";
import { MKRAssessor }from "../../../../lender/adapters/mkr/assessor.sol";


contract LenderSystemTest is TestSuite, Interest {
    MKRAssessor mkrAssessor;

    function setUp() public {
        // setup hevm
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

        bool mkrAdapter = true;
        deployContracts(mkrAdapter);
        createTestUsers();

        nftFeed_ = NFTFeedLike(address(nftFeed));

        root.relyContract(address(clerk), address(this));
        mkrAssessor = MKRAssessor(address(assessor));
        mkr.depend("currency" ,currency_);
        mkr.depend("drop", mkrLenderDeployer.seniorToken());
    }

    // setup a running pool with default values
    function _setupRunningPool() internal {
        uint seniorSupplyAmount = 1500 ether;
        uint juniorSupplyAmount = 200 ether;
        uint nftPrice = 200 ether;
        // interest rate default => 5% per day
        uint borrowAmount = 100 ether;
        uint maturityDate = 5 days;

        ModelInput memory submission = ModelInput({
            seniorSupply : 800 ether,
            juniorSupply : 200 ether,
            seniorRedeem : 0 ether,
            juniorRedeem : 0 ether
            });

        supplyAndBorrowFirstLoan(seniorSupplyAmount, juniorSupplyAmount, nftPrice, borrowAmount, maturityDate, submission);
    }

    function testMKRRaise() public {
        _setupRunningPool();
        uint preReserve = assessor.totalBalance();
        uint nav = nftFeed.calcUpdateNAV();
        uint preSeniorBalance = assessor.seniorBalance();

        uint amountDAI = 10 ether;

        clerk.raise(amountDAI);

        //raise reserves a spot for drop and locks the tin
        assertEq(assessor.seniorBalance(), safeAdd(preSeniorBalance, rmul(amountDAI, clerk.mat())));
        assertEq(assessor.totalBalance(), safeAdd(preReserve, amountDAI));

        assertEq(mkrAssessor.effectiveTotalBalance(), preReserve);
        assertEq(mkrAssessor.effectiveSeniorBalance(), preSeniorBalance);
        assertEq(clerk.remainingCredit(), amountDAI);
    }

    function testMKRDraw() public {
        _setupRunningPool();
        uint preReserve = assessor.totalBalance();
        uint nav = nftFeed.calcUpdateNAV();
        uint preSeniorBalance = assessor.seniorBalance();

        uint creditLineAmount = 10 ether;
        uint drawAmount = 5 ether;
        clerk.raise(creditLineAmount);

        //raise reserves a spot for drop and locks the tin
        assertEq(assessor.seniorBalance(), safeAdd(preSeniorBalance, rmul(creditLineAmount, clerk.mat())));
        assertEq(assessor.totalBalance(), safeAdd(preReserve, creditLineAmount));

        uint preSeniorDebt = assessor.seniorDebt();
        clerk.draw(drawAmount);

        // seniorBalance and reserve should have changed
        assertEq(mkrAssessor.effectiveTotalBalance(), safeAdd(preReserve, drawAmount));

        assertEq(safeAdd(mkrAssessor.effectiveSeniorBalance(),assessor.seniorDebt()),
            safeAdd(safeAdd(preSeniorBalance, rmul(drawAmount, clerk.mat())), preSeniorDebt));

        //raise reserves a spot for drop and locks the tin. no impact from the draw function
        assertEq(safeAdd(assessor.seniorBalance(),assessor.seniorDebt()),
            safeAdd(safeAdd(preSeniorBalance, rmul(creditLineAmount, clerk.mat())), preSeniorDebt));

        assertEq(assessor.totalBalance(), safeAdd(preReserve, creditLineAmount));
    }


    function _setUpMKRLine(uint juniorAmount, uint mkrAmount) internal {
        root.relyContract(address(reserve), address(this));

        root.relyContract(address(mkrAssessor), address(this));
        mkrAssessor.file("minSeniorRatio",0);

        // activate clerk in reserve
        reserve.depend("lending", address(clerk));

        uint juniorSupplyAmount = 200 ether;
        juniorSupply(juniorSupplyAmount);

        hevm.warp(now + 1 days);

        bool closeWithExecute = true;
        closeEpoch(true);
        assertTrue(coordinator.submissionPeriod() == false);

        uint creditLineAmount = 500 ether;
        clerk.raise(creditLineAmount);

        assertEq(clerk.remainingCredit(), creditLineAmount);
    }

    function _setUpDraw(uint mkrAmount, uint juniorAmount, uint borrowAmount) public {
        _setUpMKRLine(juniorAmount, mkrAmount);
        setupOngoingDefaultLoan(borrowAmount);
        assertEq(currency.balanceOf(address(borrower)), borrowAmount, " _setUpDraw#1");
        uint debt = 0;
        if(borrowAmount > juniorAmount) {
            debt = safeSub(borrowAmount, juniorAmount);
        }
        assertEq(clerk.debt(), debt);
    }

    function testOnDemandDraw() public {
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
    }

    function testOnDemandDrawWithStabilityFee() public {
        uint fee = 1000000564701133626865910626; // 5% per day
        mkr.file("stabilityFee", fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        hevm.warp(now + 1 days);
        assertEq(clerk.debt(), 105 ether, "testStabilityFee#2");
    }

    function testTotalBalanceBuffer() public {
        uint fee = 1000000564701133626865910626; // 5% per day
        mkr.file("stabilityFee", fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        hevm.warp(now + 1 days);

        uint debt = clerk.debt();
        uint buffer = safeSub(rmul(rpow(clerk.stabilityFee(),
                safeSub(safeAdd(block.timestamp, mkrAssessor.creditBufferTime()), block.timestamp), ONE), debt), debt);

        uint remainingCredit = clerk.remainingCredit();
        assertEq(assessor.totalBalance(), safeSub(remainingCredit, buffer));
    }

    function testLoanRepayWipe() public {
        uint fee = 1000000564701133626865910626; // 5% per day
        mkr.file("stabilityFee", fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        hevm.warp(now + 1 days);
        uint expectedDebt = 105 ether;
        assertEq(clerk.debt(), expectedDebt, "testLoanRepayWipe#1");

        uint repayAmount = 50 ether;
        repayDefaultLoan(repayAmount);

        // reduces clerk debt
        assertEq(clerk.debt(), expectedDebt-repayAmount, "testLoanRepayWipe#2");
        assertEq(reserve.totalBalance(), 0, "testLoanRepayWipe#3");
    }

    function testMKRHarvest() public {
        uint fee = uint(1000000115165872987700711356);    // 1 % day
        mkr.file("stabilityFee", fee);
        uint juniorAmount = 200 ether;
        uint mkrAmount = 500 ether;
        uint borrowAmount = 300 ether;
        _setUpDraw(mkrAmount, juniorAmount, borrowAmount);
        hevm.warp(now + 1 days);
        uint expectedDebt = 101 ether;
        assertEqTol(clerk.debt(), expectedDebt, "testMKRHarvest#1");

        emit log_named_uint("nav", nftFeed_.currentNAV());
        hevm.warp(now + 1 days);

        emit log_named_uint("nav", nftFeed_.currentNAV());

        uint seniorPrice = mkrAssessor.calcSeniorTokenPrice();
        emit log_named_uint("f", 2);
        uint juniorPrice = mkrAssessor.calcJuniorTokenPrice();
        emit log_named_uint("f", 4);

        emit log_named_uint("seniorPrice", seniorPrice);
        emit log_named_uint("juniorPrice", juniorPrice);
        assertTrue(false);
    }

}
