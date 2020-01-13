// Copyright (C) 2019 Centrifuge
//
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

pragma solidity >=0.4.24;

import "ds-note/note.sol";
import "./base.sol";


contract CurrencyLike {
    function balanceOf(address) public returns(uint);
}

contract SwitchableDistributor is Distributor {
    // ERC20
    CurrencyLike public currency;

    constructor(address shelf_) Distributor(shelf_)  public {
        borrowFromTranches = false;
    }

    bool public borrowFromTranches;

    function file(bytes32 what, bool flag) public auth {
        if (what == "borrowFromTranches") {
            borrowFromTranches = flag;
        }  else revert();
    }

    function depend(bytes32 what, address addr) public auth {
        if (what == "currency") {
            currency = CurrencyLike(currency);
        }  else revert();
    }

    function balance() public {
        if(borrowFromTranches) {
            uint repayAmount = currency.balanceOf(address(shelf));
            repayTranches(repayAmount);
            return;
        }

        uint currencyAmount = add(senior.balance(), junior.balance());
        borrowTranches(currencyAmount);
    }
}
