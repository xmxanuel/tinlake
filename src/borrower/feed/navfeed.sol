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

import "ds-note/note.sol";
import "tinlake-auth/auth.sol";
import "tinlake-math/interest.sol";
import "./nftfeed.sol";
import "../../fixed_point.sol";

// The Nav Feed contract extends the functionality of the NFT Feed by the Net Asset Value (NAV) computation of a Tinlake pool.
// NAV is computed as the sum of all discounted future values (fv) of ongoing loans (debt > 0) in the pool.
// The applied discountRate is dependant on the maturity data of the underlying collateral. The discount decreases with the maturity date approaching.
// To optimize the NAV calculation the discounting of future values happens bucketwise. FVs from assets with the same maturity date are added to one bucket.
// This safes iterations & gas, as the same discountRates can be applied per bucket.
contract NAVFeed is BaseNFTFeed, Interest, FixedPoint {

    // maturityDate is the expected date of repayment for an asset
    // nftID => maturityDate
    mapping (bytes32 => uint) public maturityDate;

    // recoveryRatePD is a combined rate that includes the probability of default for an asset of a certain risk group and its recovery rate
    // risk => recoveryRatePD
    mapping (uint => Fixed27) public recoveryRatePD;

    // futureValue of an asset based on the loan debt, interest rate, maturity date and recoveryRatePD
    // nftID => futureValue
    mapping (bytes32 => uint) public futureValue;

    // last time the NAV was updated
    uint public lastNAVUpdate;

    // timestamp => bucket
    mapping (uint => uint) public buckets;

    WriteOff [2] public writeOffs;

    struct WriteOff {
        uint rateGroup;
        // denominated in (10^27)
        Fixed27 percentage;
    }

    // discount rate applied on every asset's fv depending on its maturityDate. The discount decreases with the maturityDate approaching.
    Fixed27 public discountRate;

    // latestNAV is calculated in case of borrows & repayments between epoch executions.
    // It decreases/increases the NAV by the repaid/borrowed amount without running the NAV calculation routine.
    // This is required for more accurate Senior & JuniorAssetValue estimations between epochs
    uint public latestNAV;

    // rate group for write-offs in pile contract
    uint constant public  WRITE_OFF_PHASE_A = 1001;
    uint constant public  WRITE_OFF_PHASE_B = 1002;

    constructor () public {
        wards[msg.sender] = 1;
    }

    function init() public {
        require(ceilingRatio[0] == 0, "already-initialized");

        // gas optimized initialization of writeOffs and risk groups
        // write off are hardcoded in the contract instead of init function params

        // risk groups are extended by the recoveryRatePD parameter compared with NFTFeed

        // The following score cards just examples that are mostly optimized for the system test cases

        // risk group: 0
        file("riskGroup",
            0,                                      // riskGroup:       0
            8*10**26,                               // thresholdRatio   80%
            6*10**26,                               // ceilingRatio     60%
            ONE,                                    // interestRate     1.0
            ONE                                     // recoveryRatePD:  1.0
        );

        // risk group: 1
        file("riskGroup",
            1,                                      // riskGroup:       1
            7*10**26,                               // thresholdRatio   70%
            5*10**26,                               // ceilingRatio     50%
            uint(1000000003593629043335673583),     // interestRate     12% per year
            90 * 10**25                             // recoveryRatePD:  0.9
        );

        // risk group: 2
        file("riskGroup",
            2,                                      // riskGroup:       2
            7*10**26,                               // thresholdRatio   70%
            5*10**26,                               // ceilingRatio     50%
            uint(1000000564701133626865910626),     // interestRate     5% per day
            90 * 10**25                             // recoveryRatePD:  0.9
        );

        // risk group: 3
        file("riskGroup",
            3,                                      // riskGroup:       3
            7*10**26,                               // thresholdRatio   70%
            ONE,                                    // ceilingRatio     100%
            uint(1000000564701133626865910626),     // interestRate     5% per day
            ONE                                     // recoveryRatePD:  1.0
        );

        // risk group: 4 (used by collector tests)
        file("riskGroup",
            4,                                      // riskGroup:       4
            5*10**26,                               // thresholdRatio   50%
            6*10**26,                               // ceilingRatio     60%
            uint(1000000564701133626865910626),     // interestRate     5% per day
            ONE                                     // recoveryRatePD:  1.0
        );

        /// Overdue loans (= loans that were not repaid by the maturityDate) are moved to write Offs
        // 6% interest rate & 60% write off
        setWriteOff(0, WRITE_OFF_PHASE_A, uint(1000000674400000000000000000), 6 * 10**26);
        // 6% interest rate & 80% write off
        setWriteOff(1, WRITE_OFF_PHASE_B, uint(1000000674400000000000000000), 8 * 10**26);
    }

    function file(bytes32 name, uint risk_, uint thresholdRatio_, uint ceilingRatio_, uint rate_, uint recoveryRatePD_) public auth  {
        if(name == "riskGroup") {
            file("riskGroupNFT", risk_, thresholdRatio_, ceilingRatio_, rate_);
            recoveryRatePD[risk_] = Fixed27(recoveryRatePD_);

        } else {revert ("unknown name");}
    }

    function setWriteOff(uint phase_, uint group_, uint rate_, uint writeOffPercentage_) internal {
        writeOffs[phase_] = WriteOff(group_, Fixed27(writeOffPercentage_));
        pile.file("rate", group_, rate_);
    }

    function uniqueDayTimestamp(uint timestamp) public pure returns (uint) {
        return (1 days) * (timestamp/(1 days));
    }

    /// maturityDate is a unix timestamp
    function file(bytes32 name, bytes32 nftID_, uint maturityDate_) public auth {
        // maturity date only can be changed when there is no debt on the collateral -> futureValue == 0
        if (name == "maturityDate") {
            require((futureValue[nftID_] == 0), "can-not-change-maturityDate-outstanding-debt");
            maturityDate[nftID_] = uniqueDayTimestamp(maturityDate_);
        } else { revert("unknown config parameter");}
    }

    function file(bytes32 name, uint value) public auth {
        if (name == "discountRate") {
            discountRate = Fixed27(value);
        } else { revert("unknown config parameter");}
    }

    // In case of successful borrow the latestNAV is increased by the borrowed amount
    function borrow(uint loan, uint amount) external auth returns(uint navIncrease) {
        calcUpdateNAV();
        navIncrease = _borrow(loan, amount);
        latestNAV = safeAdd(latestNAV, navIncrease);
        return navIncrease;
    }

    // On borrow: the discounted future value of the asset is computed based on the loan amount and addeed to the bucket with the according maturity Date
    function _borrow(uint loan, uint amount) internal returns(uint navIncrease) {
        // ceiling check uses existing loan debt
        require(ceiling(loan) >= safeAdd(borrowed[loan], amount), "borrow-amount-too-high");

        bytes32 nftID_ = nftID(loan);
        uint maturityDate_ = maturityDate[nftID_];
        // maturity date has to be a value in the future
        require(maturityDate_ > block.timestamp, "maturity-date-is-not-in-the-future");

        // calculate amount including fixed fee if applicatable
        (, , , , uint fixedRate) = pile.rates(pile.loanRates(loan));
        uint amountIncludingFixed =  safeAdd(amount, rmul(amount, fixedRate));
        // calculate future value FV
        uint fv = calcFutureValue(loan, amountIncludingFixed, maturityDate_, recoveryRatePD[risk[nftID_]].value);
        futureValue[nftID_] = safeAdd(futureValue[nftID_], fv);

        // add future value to the bucket of assets with the same maturity date

        buckets[maturityDate_] = safeAdd(buckets[maturityDate_], fv);


        // increase borrowed amount for future ceiling computations
        borrowed[loan] = safeAdd(borrowed[loan], amount);

        // return increase NAV amount
        return calcDiscount(fv, uniqueDayTimestamp(block.timestamp), maturityDate_);
    }

    // calculate the future value based on the amount, maturityDate interestRate and recoveryRate
    function calcFutureValue(uint loan, uint amount, uint maturityDate_, uint recoveryRatePD_) public returns(uint) {
        // retrieve interest rate from the pile
        (, ,uint loanInterestRate, ,) = pile.rates(pile.loanRates(loan));
        return rmul(rmul(rpow(loanInterestRate, safeSub(maturityDate_, uniqueDayTimestamp(now)), ONE), amount), recoveryRatePD_);
    }

    /// update the nft value and change the risk group
    function update(bytes32 nftID_, uint value, uint risk_) public auth {
        nftValues[nftID_] = value;

        // no change in risk group
        if (risk_ == risk[nftID_]) {
            return;
        }

        // nfts can only be added to risk groups that are part of the score card
        require(thresholdRatio[risk_] != 0, "risk group not defined in contract");
        risk[nftID_] = risk_;

        // no currencyAmount borrowed yet
        if (futureValue[nftID_] == 0) {
            return;
        }

        uint loan = shelf.nftlookup(nftID_);
        uint maturityDate_ = maturityDate[nftID_];

        // Changing the risk group of an nft, might lead to a new interest rate for the dependant loan.
        // New interest rate leads to a future value.
        // recalculation required
        buckets[maturityDate_] = safeSub(buckets[maturityDate_], futureValue[nftID_]);

        futureValue[nftID_] = calcFutureValue(loan, pile.debt(loan), maturityDate[nftID_], recoveryRatePD[risk[nftID_]].value);
        buckets[maturityDate_] = safeAdd(buckets[maturityDate_], futureValue[nftID_]);
    }

    // In case of successful repayment the latestNAV is decreased by the repaid amount
    function repay(uint loan, uint amount) external auth returns (uint navDecrease) {
        calcUpdateNAV();
        navDecrease = _repay(loan, amount);

        if(navDecrease < latestNAV) {
            latestNAV = safeSub(latestNAV, navDecrease);
            return navDecrease;
        }
        latestNAV = 0;
        return navDecrease;
    }

    // On repayment: adjust future value bucket according to repayment amount
    function _repay(uint loan, uint amount) internal returns (uint navDecrease) {
        bytes32 nftID_ = nftID(loan);
        uint maturityDate_ = maturityDate[nftID_];

        uint nnow = uniqueDayTimestamp(block.timestamp);
        // no fv decrease calculation needed if maturity date is in the past
        // repayment on maturity date is fine
        // unique day timestamp is always 00:00 am
        if (maturityDate_ < nnow) {
            emit log_named_uint("ff", 1);
            return 0;
        }

        // remove future value for loan from bucket
        buckets[maturityDate_] = safeSub(buckets[maturityDate_], futureValue[nftID_]);

        uint debt = pile.debt(loan);
        debt = safeSub(debt, amount);

        uint fv = 0;
        uint preFutureValue = futureValue[nftID_];

        // in case of partial repayment, compute the fv of the remaining debt and add to the according fv bucket
        if (debt != 0) {
            fv = calcFutureValue(loan, debt, maturityDate_, recoveryRatePD[risk[nftID_]].value);
            buckets[maturityDate_] = safeAdd(buckets[maturityDate_], fv);
        }

        futureValue[nftID_] = fv;

        // return decrease NAV amount
        return calcDiscount(safeSub(preFutureValue, fv), uniqueDayTimestamp(block.timestamp), maturityDate_);

    }

    function calcDiscount(uint fv, uint normalizedBlockTimestamp, uint maturityDate_) public view returns (uint result) {
        return rdiv(fv, rpow(discountRate.value, safeSub(maturityDate_, normalizedBlockTimestamp), ONE));
    }

    function secureSub(uint x, uint y) public pure returns(uint) {
        if(y > x) {
            return 0;
        }
        return safeSub(x, y);
    }

    function currentNAV() public view returns(uint) {
        if (latestNAV == 0) {
            return currentWriteOffs();
        }

        uint nnow = uniqueDayTimestamp(block.timestamp);
        uint nLastUpdate = uniqueDayTimestamp(lastNAVUpdate);

        uint nav_ = rmul(latestNAV, rpow(discountRate.value, safeSub(nnow, nLastUpdate), ONE));

        uint diff = 0;
        for(uint i = nLastUpdate; i < nnow; i = i + 1 days) {
            diff = safeAdd(diff, rmul(buckets[i], rpow(discountRate.value, safeSub(nnow, i), ONE)));
        }

        nav_ = secureSub(nav_, diff);
        return safeAdd(nav_, currentWriteOffs());
    }

    function currentWriteOffs() public view returns(uint) {
        // include ovedue assets to the current NAV calculation
        uint sum = 0;
        for (uint i = 0; i < writeOffs.length; i++) {
            // multiply writeOffGroupDebt with the writeOff rate
            sum = safeAdd(sum, rmul(pile.rateDebt(writeOffs[i].rateGroup), writeOffs[i].percentage.value));
        }
        return sum;
    }

    function calcUpdateNAV() public returns(uint) {
        latestNAV = currentNAV();
        lastNAVUpdate = block.timestamp;
        return latestNAV;
    }

    /// workaround for transition phase between V2 & V3
    function totalValue() public view returns(uint) {
        return currentNAV();
    }

    function dateBucket(uint timestamp) public view returns (uint) {
        return buckets[timestamp];
    }
}
