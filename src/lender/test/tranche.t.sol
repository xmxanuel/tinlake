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

import "ds-test/test.sol";
import "tinlake-math/math.sol";

import "./../tranche.sol";
import "../../test/simple/token.sol";
import "../test/mock/reserve.sol";
import "./../ticker.sol";

contract Hevm {
    function warp(uint256) public;
}



contract ReserveMockTranche is ReserveMock {
    constructor(SimpleToken currency, address tranche) public {
        currency.approve(tranche, uint(-1));
    }
}

contract TrancheTest is DSTest, Math, FixedPoint {
    Tranche tranche;
    SimpleToken token;
    SimpleToken currency;
    ReserveMock reserve;
    Ticker ticker;

    Hevm hevm;

    address tranche_;
    address reserve_;
    address self;

    uint256 constant ONE = 10**27;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(1595247588);
        self = address(this);

        ticker = new Ticker();
        token = new SimpleToken("TIN", "Tranche", "1", 0);
        currency = new SimpleToken("CUR", "Currency", "1", 0);
        reserve = new ReserveMockTranche(currency, self);
        reserve_ = address(reserve);

        tranche = new Tranche(address(currency), address(token));
        tranche.depend("ticker", address(ticker));
        tranche.depend("reserve", reserve_);

        tranche_ = address(tranche);


    }

    function supplyOrder(uint amount) public {
        currency.mint(self, amount);
        currency.approve(tranche_, amount);
        tranche.supplyOrder(self, amount);

        (,uint supply,) = tranche.users(self);
        assertEq(supply, amount);

    }

    function testSupplyOrder() public {
        uint amount = 100 ether;
        supplyOrder(amount);
        assertEq(tranche.globalSupply(), amount);

        // change order
        amount = 120 ether;
        supplyOrder(amount);
        assertEq(tranche.globalSupply(), amount);

    }

    function testSimpleCloseEpoch() public {
        uint amount = 100 ether;
        supplyOrder(amount);
        assertEq(tranche.globalSupply(), amount);
        (uint globalSupply, uint globalRedeem) = tranche.closeEpoch();
        assertEq(globalSupply, amount);
    }

    function testFailSupplyAfterCloseEpoch() public {
        uint amount = 100 ether;
        supplyOrder(amount);
        tranche.closeEpoch();
        supplyOrder(120 ether);

    }

    function testSimpleEpochUpdate() public {
        uint amount = 100 ether;
        supplyOrder(amount);
        tranche.closeEpoch();

        // 60 % fulfillment
        uint supplyFulfillment_ = 6 * 10**26;
        uint redeemFulfillment_ = ONE;
        uint tokenPrice_ = ONE;

        tranche.epochUpdate(supplyFulfillment_, redeemFulfillment_, tokenPrice_, amount, 0);

        assertEq(tranche.globalSupply(), 40 ether);
        assertTrue(tranche.waitingForUpdate() == false);
    }

    function testSimpleDisburse() public {
        uint amount = 100 ether;
        supplyOrder(amount);
        tranche.closeEpoch();

        // 60 % fulfillment
        uint supplyFulfillment_ = 6 * 10**26;
        uint redeemFulfillment_ = ONE;
        uint tokenPrice_ = ONE;

        tranche.epochUpdate(supplyFulfillment_, redeemFulfillment_, tokenPrice_, amount, 0);

        tranche.closeEpoch();

        // 20 %
        supplyFulfillment_ = 2 * 10**26;
        redeemFulfillment_ = ONE;

        // should receive 80% => 80 ether
        (uint payoutCurrencyAmount, uint payoutTokenAmount,
        uint usrRemainingSupply,  uint usrRemainingRedeem) =  tranche.calcDisburse(self);

        assertEq(payoutCurrencyAmount, 80 ether);
        assertEq(usrRemainingSupply, 20 ether);

    }
}
