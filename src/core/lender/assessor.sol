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

pragma solidity >=0.4.24;

import "ds-note/note.sol";
import "ds-math/math.sol";

contract TrancheLike {
    function balance() public returns(uint);
    function tokenSupply() public returns(uint);
}
contract SeniorTrancheLike {
    function debt() public returns(uint);
}

contract PileLike {
    function debt() public returns(uint);
}

contract Assessor is DSNote,DSMath {

    uint256 constant ONE = 10 ** 27;

    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public auth note { wards[usr] = 1; }
    function deny(address usr) public auth note { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Tranches ---
    address public senior;
    address public junior;

    PileLike pile;

    // initial net asset value
    uint public initialNAV;

    // --- Assessor ---
    // computes the current asset value for tranches.
    constructor(address pile_) public {
        wards[msg.sender] = 1;
        pile = PileLike(pile_);
        initialNAV = 1;
    }

    // --- Calls ---
    function file(bytes32 what, address addr_) public auth {
        if (what == "junior") { junior = addr_; }
        else if (what == "senior") { senior = addr_; }
        else revert();
    }

    function file(bytes32 what, uint value) public auth {
        if (what == "initialNAV") { initialNAV = value; }
        else revert();
    }

    function calcAssetValue(address tranche) public returns(uint) {
        uint trancheReserve = TrancheLike(tranche).balance();
        uint poolValue = pile.debt();
        if (tranche == junior) {
            return calcJuniorAssetValue(poolValue, trancheReserve, seniorDebt());
        }
        return calcSeniorAssetValue(poolValue, trancheReserve, SeniorTrancheLike(tranche).debt(), juniorReserve());
    }

    function calcTokenPrice() public returns (uint) {
        return mul(_calcTokenPrice(), initialNAV);
    }

    function _calcTokenPrice() internal returns (uint) {
        uint tokenSupply = TrancheLike(msg.sender).tokenSupply();
        uint assetValue = calcAssetValue(msg.sender);
        if (tokenSupply == 0) {
            return ONE;
        }
        if (assetValue == 0) {
            revert("tranche is bankrupt");
        }
        return rdiv(assetValue, tokenSupply);
    }

    // Tranche.assets (Junior) = (Pool.value + Tranche.reserve - Senior.debt) > 0 && (Pool.value - Tranche.reserve - Senior.debt) || 0
    function calcJuniorAssetValue(uint poolValue, uint trancheReserve, uint seniorDebt) internal returns (uint) {
        int assetValue = int(poolValue + trancheReserve - seniorDebt);
        return (assetValue > 0) ? uint(assetValue) : 0;
    }

    // Tranche.assets (Senior) = (Tranche.debt < (Pool.value + Junior.reserve)) && (Senior.debt + Tranche.reserve) || (Pool.value + Junior.reserve + Tranche.reserve)
    function calcSeniorAssetValue(uint poolValue, uint trancheReserve, uint trancheDebt, uint juniorReserve) internal returns (uint) {
        return ((poolValue + juniorReserve) >= trancheDebt) ? (trancheDebt + trancheReserve) : (poolValue + juniorReserve + trancheReserve);
    }

    function juniorReserve() internal returns (uint) {
        return TrancheLike(junior).balance();
    }

    function seniorDebt() internal returns (uint) {
        return (senior != address(0x0)) ? SeniorTrancheLike(senior).debt() : 0;
    }
}