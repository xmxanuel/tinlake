// principal.sol
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
pragma experimental ABIEncoderV2;

import "ds-note/note.sol";
import "tinlake-math/math.sol";
import "tinlake-auth/auth.sol";

// Principal is an implementation of the Ceiling module that defines the max amount a user can borrow.
// The principal of each loan is decreased with borrow transactions. Accrued interest is ignored.
contract Principal is DSNote, Auth, Math {
    mapping (uint => uint) public values;

    constructor() public {
        wards[msg.sender] = 1;
    }

    function ceiling(uint loan) public returns(uint) {
        return values[loan];
    }

    function file(uint loan, uint principal) public note auth {
        values[loan] = principal;
    }

    function borrow(uint loan, uint amount) public auth {
        require(values[loan] >= amount);
        values[loan] = sub(values[loan], amount);
    }

    function repay(uint loan, uint amount) public auth {
    }
}