// Copyright (C) 2018  Rain <rainbreak@riseup.net>, Centrifuge
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

// Beans
// Keeps track of interest rate accumulators (rateIndex values) for all interest rate categories.
// Calculates debt each loan according to its interest rate category and debtBalance value.
contract Beans is DSNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public auth note { wards[usr] = 1; }
    function deny(address usr) public auth note { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }
    
    // --- Data ---
    // https://github.com/makerdao/dsr/blob/master/src/dsr.sol
    struct Rate {
        uint debt;  // Total debt of all loans with this rate
        uint rateIndex; // Accumulated rates
        uint ratePerSecond; // Accumulation per second
        uint48 lastUpdated; // Last time the rate was accumulated
    }

    mapping (uint => Rate) public rates;
    mapping (uint => uint) public debtBalance;

    uint public totalDebt;

    constructor() public {
        wards[msg.sender] = 1;
        rates[0].rateIndex = ONE;
        rates[0].ratePerSecond = ONE;
    }

    function file(uint rate, uint speed_) public auth note {
        require(speed_ != 0);
        rates[rate].ratePerSecond = speed_;
        rates[rate].rateIndex = ONE;
        rates[rate].lastUpdated = uint48(now);
        drip(rate);
    }

    // --- Math ---
    uint256 constant ONE = 10 ** 27;
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                let xx := mul(x, x)
                if iszero(eq(div(xx, x), x)) { revert(0,0) }
                let xxRound := add(xx, half)
                if lt(xxRound, xx) { revert(0,0) }
                x := div(xxRound, base)
                if mod(n,2) {
                    let zx := mul(z, x)
                    if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                    let zxRound := add(zx, half)
                    if lt(zxRound, zx) { revert(0,0) }
                    z := div(zxRound, base)
                }
            }
            }
        }
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / ONE;
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = add(mul(x, ONE), y / 2) / y;
    }

    function div(uint x, uint y) internal pure returns (uint z) {
        z = x / y;
    }

    function incLoanDebt(uint loan, uint rate, uint wad) public auth note {
        require(now == rates[rate].lastUpdated);
        debtBalance[loan] = add(debtBalance[loan], calcDebtBalance(rates[rate].rateIndex, wad));
        incTotalDebt(rate, wad);
    }

    function decLoanDebt(uint loan, uint rate, uint wad) public auth note {
        require(now == rates[rate].lastUpdated);
        debtBalance[loan] = sub(debtBalance[loan], calcDebtBalance(rates[rate].rateIndex, wad));
        decTotalDebt(rate, wad);
    }

    function compounding(uint rate) public view returns (uint, uint, uint) {
        uint48 lastUpdated = rates[rate].lastUpdated;
        require(now >= lastUpdated);
        uint ratePerSecond = rates[rate].ratePerSecond;

        uint rateIndex = rates[rate].rateIndex;
        uint debt_ = rates[rate].debt;

        // compounding in seconds
        uint latest = rmul(rpow(ratePerSecond, now - lastUpdated, ONE), rateIndex);
        uint chi_ = rdiv(latest, rateIndex);
        uint wad = rmul(debt_, chi_) - debt_;
        return (latest, chi_, wad);
    }

    // --- Rate Accumulation ---
    function drip(uint rate) public {
        if (now >= rates[rate].lastUpdated) {
            (uint latest, , uint wad) = compounding(rate);
            rates[rate].rateIndex = latest;
            rates[rate].lastUpdated = uint48(now);
            incTotalDebt(rate, wad);   
        }
    }

    function burden(uint loan, uint rate) public view returns (uint) {
        uint rateIndex = rates[rate].rateIndex;
        if (now >= rates[rate].lastUpdated) {
            (rateIndex, ,) = compounding(rate);
        }
        return calcDebt(rateIndex, debtBalance[loan]);
    }

    function debtOf(uint loan, uint rate) public view returns(uint) {
        return calcDebt(rates[rate].rateIndex, debtBalance[loan]);
    }
    
    function incTotalDebt(uint rate, uint wad) private {
        rates[rate].debt = add(rates[rate].debt, wad);
        totalDebt = add(totalDebt, wad);
    }

    function decTotalDebt(uint rate, uint wad) private {
        rates[rate].debt = sub(rates[rate].debt, wad);
        totalDebt = sub(totalDebt, wad);
    }

    function calcDebtBalance(uint rateIndex, uint wad) private view returns (uint) {
        return rdiv(wad, rateIndex);
    }

    function calcDebt(uint rateIndex, uint pie_) private view returns (uint) {
        return rmul(pie_, rateIndex);
    }
}