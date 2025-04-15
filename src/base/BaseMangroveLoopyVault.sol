// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import { Ownable, Ownable2Step } from "@openzeppelin-contracts/access/Ownable2Step.sol";
import { ERC20Permit } from "@openzeppelin-contracts/token/ERC20/extensions/ERC20Permit.sol";
import {
    ERC20,
    ERC4626,
    IERC20,
    IERC4626,
    Math,
    SafeERC20
} from "@openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import { PendingAddress, PendingLib, PendingUint192 } from "src/libraries/PendingLib.sol";
import { UtilsLib } from "src/libraries/UtilsLib.sol";

/// @title BaseMangroveLoopyVault
/// @author Mangrove
/// @notice An ERC4626-compliant vault with role-based access control and fee mechanisms
/// @dev Modified from Morpho's vault implementations
abstract contract BaseMangroveLoopyVault is ERC4626, ERC20Permit, Ownable {
    using Math for uint256;
    using UtilsLib for uint256;
    using PendingLib for PendingAddress;
    using PendingLib for PendingUint192;
    using SafeERC20 for IERC20;

    // Events
    /// @notice Emitted when a new curator is set
    /// @param newCurator Address of the new curator
    event SetCurator(address indexed newCurator);

    /// @notice Emitted when an address's allocator status is updated
    /// @param allocator Address that had its allocator status updated
    /// @param isAllocator Whether the address is now an allocator or not
    event SetIsAllocator(address indexed allocator, bool isAllocator);

    /// @notice Emitted when a new skim recipient is set
    /// @param newSkimRecipient Address of the new skim recipient
    event SetSkimRecipient(address indexed newSkimRecipient);

    /// @notice Emitted when a new timelock is submitted (pending)
    /// @param newTimelock The proposed new timelock duration
    event SubmitTimelock(uint256 newTimelock);

    /// @notice Emitted when the timelock is updated
    /// @param sender Address that triggered the timelock update
    /// @param newTimelock The new timelock duration
    event SetTimelock(address indexed sender, uint256 newTimelock);

    /// @notice Emitted when tokens are skimmed from the contract
    /// @param sender Address that initiated the skim
    /// @param token Address of the token being skimmed
    /// @param amount Amount of tokens skimmed
    event Skim(address indexed sender, address indexed token, uint256 amount);

    /// @notice Emitted when the fee percentage is set
    /// @param sender Address that set the fee
    /// @param fee The new fee percentage (in 18 decimals, e.g., 0.5e18 = 50%)
    event SetFee(address indexed sender, uint96 fee);

    /// @notice Emitted when the fee recipient is set
    /// @param newFeeRecipient Address of the new fee recipient
    event SetFeeRecipient(address indexed newFeeRecipient);

    /// @notice Emitted when a new guardian is submitted (pending)
    /// @param newGuardian Address of the proposed new guardian
    event SubmitGuardian(address indexed newGuardian);

    /// @notice Emitted when the guardian is updated
    /// @param sender Address that triggered the guardian update
    /// @param newGuardian Address of the new guardian
    event SetGuardian(address indexed sender, address indexed newGuardian);

    /// @notice Emitted when lastTotalAssets is updated
    /// @param updatedTotalAssets The new total assets value
    event UpdateLastTotalAssets(uint256 updatedTotalAssets);

    /// @notice Emitted when interest is accrued
    /// @param newTotalAssets The new total assets after accruing interest
    /// @param feeShares Amount of shares minted as fees
    event AccrueInterest(uint256 newTotalAssets, uint256 feeShares);

    /// @notice Emitted when a new deposits cap is submitted (pending)
    /// @param newDepositsCap The proposed new deposits cap
    event SubmitDepositsCap(uint256 newDepositsCap);

    /// @notice Emitted when the deposits cap is updated
    /// @param sender Address that triggered the deposits cap update
    /// @param newDepositsCap The new deposits cap
    event SetDepositsCap(address indexed sender, uint256 newDepositsCap);

    // Errors
    /// @notice Thrown when a caller doesn't have the curator role
    error NotCuratorRole();

    /// @notice Thrown when a caller doesn't have the allocator role
    error NotAllocatorRole();

    /// @notice Thrown when a caller doesn't have the guardian role
    error NotGuardianRole();

    /// @notice Thrown when a caller has neither the curator nor guardian role
    error NotCuratorNorGuardianRole();

    /// @notice Thrown when there's no pending value to accept
    error NoPendingValue();

    /// @notice Thrown when the timelock period hasn't elapsed yet
    error TimelockNotElapsed();

    /// @notice Thrown when trying to set a value that's already set
    error AlreadySet();

    /// @notice Thrown when trying to use a zero address where not allowed
    error ZeroAddress();

    /// @notice Thrown when trying to set a fee higher than the maximum
    error MaxFeeExceeded();

    /// @notice Thrown when the fee recipient is zero but the fee isn't
    error ZeroFeeRecipient();

    /// @notice Thrown when there's already a pending value
    error AlreadyPending();

    /// @notice Thrown when the timelock is above the maximum allowed
    error AboveMaxTimelock();

    /// @notice Thrown when the timelock is below the minimum allowed
    error BelowMinTimelock();

    /* STORAGE */

    /// @notice The maximum delay of a timelock (2 weeks)
    uint256 public constant MAX_TIMELOCK = 2 weeks;

    /// @notice The minimum delay of a timelock (1 day)
    uint256 public constant MIN_TIMELOCK = 1 days;

    /// @notice The maximum number of markets in the supply/withdraw queue
    uint256 public constant MAX_QUEUE_LENGTH = 30;

    /// @notice The maximum fee the vault can have (50%)
    uint256 public constant MAX_FEE = 0.5e18;

    /// @notice Address of the vault curator
    /// @dev The curator has special permissions for vault management
    address public curator;

    /// @notice Mapping of addresses to their allocator status
    /// @dev Allocators have permissions to manage the vault's allocations
    mapping(address => bool) public isAllocator;

    /// @notice Address of the vault guardian
    /// @dev The guardian has oversight capabilities and emergency powers
    address public guardian;

    /// @notice The duration of the timelock for timelocked operations
    uint256 public timelock;

    /// @notice Maximum amount of assets that can be deposited into the vault
    uint256 public depositsCap;

    /// @notice Pending guardian address with its timelock information
    PendingAddress public pendingGuardian;

    /// @notice Pending deposits cap with its timelock information
    PendingUint192 public pendingDepositsCap;

    /// @notice Pending timelock duration with its timelock information
    PendingUint192 public pendingTimelock;

    /// @notice Fee percentage charged on generated yield (in 18 decimals, e.g., 0.5e18 = 50%)
    uint96 public fee;

    /// @notice Address that receives the collected fees
    address public feeRecipient;

    /// @notice Address that receives tokens skimmed from the contract
    address public skimRecipient;

    /// @notice Last recorded total assets value, used for fee calculation
    uint256 public lastTotalAssets;

    /// @notice Reverts if the caller doesn't have the curator role
    /// @dev Curator role is granted to the curator address or the owner
    modifier onlyCuratorRole() {
        address sender = _msgSender();
        if (sender != curator && sender != owner()) revert NotCuratorRole();

        _;
    }

    /// @notice Reverts if the caller doesn't have the allocator role
    /// @dev Allocator role is granted to addresses in the isAllocator mapping, the curator, or the owner
    modifier onlyAllocatorRole() {
        address sender = _msgSender();
        if (!isAllocator[sender] && sender != curator && sender != owner()) {
            revert NotAllocatorRole();
        }

        _;
    }

    /// @notice Reverts if the caller doesn't have the guardian role
    /// @dev Guardian role is granted to the guardian address or the owner
    modifier onlyGuardianRole() {
        if (_msgSender() != owner() && _msgSender() != guardian) revert NotGuardianRole();

        _;
    }

    /// @notice Reverts if the caller doesn't have the curator nor the guardian role
    /// @dev Combined check for operations that can be performed by either role
    modifier onlyCuratorOrGuardianRole() {
        if (_msgSender() != guardian && _msgSender() != curator && _msgSender() != owner()) {
            revert NotCuratorNorGuardianRole();
        }

        _;
    }

    /// @notice Makes sure conditions are met to accept a pending value
    /// @dev Reverts if there's no pending value or the timelock has not elapsed
    /// @param validAt The timestamp when the pending value becomes valid
    modifier afterTimelock(uint256 validAt) {
        if (validAt == 0) revert NoPendingValue();
        if (block.timestamp < validAt) revert TimelockNotElapsed();

        _;
    }

    /// @notice Initializes the BaseMangroveLoopyVault
    /// @dev Sets up the vault with initial parameters
    /// @param owner Address of the vault owner
    /// @param initialTimelock Initial timelock duration
    /// @param _asset Address of the asset token managed by the vault
    /// @param _name Name of the vault token
    /// @param _symbol Symbol of the vault token
    constructor(
        address owner,
        uint256 initialTimelock,
        address _asset,
        string memory _name,
        string memory _symbol
    )
        ERC4626(IERC20(_asset))
        ERC20Permit(_name)
        ERC20(_name, _symbol)
        Ownable(owner)
    {
        _checkTimelockBounds(initialTimelock);
        _setTimelock(initialTimelock);
    }

    /// @inheritdoc ERC4626
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        return depositsCap.zeroFloorSub(totalAssets());
    }

    /// @notice Sets a new curator for the vault
    /// @dev Only callable by the owner
    /// @param newCurator Address of the new curator
    function setCurator(address newCurator) external onlyOwner {
        if (newCurator == curator) revert AlreadySet();

        curator = newCurator;

        emit SetCurator(newCurator);
    }

    /// @notice Sets an address's allocator status
    /// @dev Only callable by the owner
    /// @param newAllocator Address to update
    /// @param newIsAllocator Whether the address should be an allocator
    function setIsAllocator(address newAllocator, bool newIsAllocator) external onlyOwner {
        if (isAllocator[newAllocator] == newIsAllocator) revert AlreadySet();

        isAllocator[newAllocator] = newIsAllocator;

        emit SetIsAllocator(newAllocator, newIsAllocator);
    }

    /// @notice Sets a new skim recipient
    /// @dev Only callable by the owner
    /// @param newSkimRecipient Address of the new skim recipient
    function setSkimRecipient(address newSkimRecipient) external onlyOwner {
        if (newSkimRecipient == skimRecipient) revert AlreadySet();

        skimRecipient = newSkimRecipient;

        emit SetSkimRecipient(newSkimRecipient);
    }

    /// @notice Submits a new timelock duration for approval
    /// @dev Only callable by the owner. Immediately sets if increasing, else requires timelock
    /// @param newTimelock The proposed new timelock duration
    function submitTimelock(uint256 newTimelock) external onlyOwner {
        if (newTimelock == timelock) revert AlreadySet();
        if (pendingTimelock.validAt != 0) revert AlreadyPending();
        _checkTimelockBounds(newTimelock);

        if (newTimelock > timelock) {
            _setTimelock(newTimelock);
        } else {
            // Safe "unchecked" cast because newTimelock <= MAX_TIMELOCK.
            pendingTimelock.update(uint184(newTimelock), timelock);

            emit SubmitTimelock(newTimelock);
        }
    }

    /// @notice Submits a new deposits cap for approval
    /// @dev This function has an implementation issue and needs to be fixed to update pendingDepositsCap
    /// @param newTimelock Currently incorrectly named - should be newDepositsCap
    function submitDepositsCap(uint256 newTimelock) external onlyOwner {
        if (newTimelock == timelock) revert AlreadySet();
        if (pendingTimelock.validAt != 0) revert AlreadyPending();
        _checkTimelockBounds(newTimelock);

        if (newTimelock > timelock) {
            _setTimelock(newTimelock);
        } else {
            // Safe "unchecked" cast because newTimelock <= MAX_TIMELOCK.
            pendingTimelock.update(uint184(newTimelock), timelock);

            emit SubmitTimelock(newTimelock);
        }
    }

    /// @notice Transfers any tokens held by the contract to the skim recipient
    /// @dev Can be called by anyone, but requires a skim recipient to be set
    /// @param token Address of the token to skim
    function skim(address token) external {
        if (skimRecipient == address(0)) revert ZeroAddress();

        uint256 amount = IERC20(token).balanceOf(address(this));

        IERC20(token).safeTransfer(skimRecipient, amount);

        emit Skim(_msgSender(), token, amount);
    }

    /// @notice Sets a new fee percentage
    /// @dev Only callable by the owner. Accrues fee before changing.
    /// @param newFee The new fee percentage (in 18 decimals)
    function setFee(uint256 newFee) external onlyOwner {
        if (newFee == fee) revert AlreadySet();
        if (newFee > MAX_FEE) revert MaxFeeExceeded();
        if (newFee != 0 && feeRecipient == address(0)) revert ZeroFeeRecipient();

        // Accrue fee using the previous fee set before changing it.
        _updateLastTotalAssets(_accrueFee());

        // Safe "unchecked" cast because newFee <= MAX_FEE.
        fee = uint96(newFee);

        emit SetFee(_msgSender(), fee);
    }

    /// @notice Sets a new fee recipient
    /// @dev Only callable by the owner. Accrues fee before changing.
    /// @param newFeeRecipient Address of the new fee recipient
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        if (newFeeRecipient == feeRecipient) revert AlreadySet();
        if (newFeeRecipient == address(0) && fee != 0) revert ZeroFeeRecipient();

        // Accrue fee to the previous fee recipient set before changing it.
        _updateLastTotalAssets(_accrueFee());

        feeRecipient = newFeeRecipient;

        emit SetFeeRecipient(newFeeRecipient);
    }

    /// @notice Submits a new guardian for approval
    /// @dev Only callable by the owner. Immediately sets if no guardian, else requires timelock
    /// @param newGuardian Address of the proposed new guardian
    function submitGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == guardian) revert AlreadySet();
        if (pendingGuardian.validAt != 0) revert AlreadyPending();

        if (guardian == address(0)) {
            _setGuardian(newGuardian);
        } else {
            pendingGuardian.update(newGuardian, timelock);

            emit SubmitGuardian(newGuardian);
        }
    }

    /// @notice Calculates maximum allowed leverage factor based on market parameters
    /// @return Maximum leverage factor
    function maxLeverageFactor() public view virtual returns (uint256);

    /// @notice Calculates current leverage factor
    /// @return Current leverage factor
    function currentLeverageFactor() public view virtual returns (uint256);

    /// @notice Converts assets to shares, taking into account accrued fees
    /// @dev Overrides ERC4626 implementation to account for fee accrual
    /// @param assets Amount of assets to convert
    /// @param rounding Rounding mode to use in the conversion
    /// @return Amount of shares corresponding to the assets
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();

        return _convertToSharesWithTotals(assets, totalSupply() + feeShares, newTotalAssets, rounding);
    }

    /// @notice Converts shares to assets, taking into account accrued fees
    /// @dev Overrides ERC4626 implementation to account for fee accrual
    /// @param shares Amount of shares to convert
    /// @param rounding Rounding mode to use in the conversion
    /// @return Amount of assets corresponding to the shares
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        (uint256 feeShares, uint256 newTotalAssets) = _accruedFeeShares();

        return _convertToAssetsWithTotals(shares, totalSupply() + feeShares, newTotalAssets, rounding);
    }

    /// @notice Converts assets to shares using provided total values
    /// @dev Used internally for more accurate conversions during fee accrual
    /// @param assets Amount of assets to convert
    /// @param newTotalSupply Total supply to use in the conversion
    /// @param newTotalAssets Total assets to use in the conversion
    /// @param rounding Rounding mode to use in the conversion
    /// @return Amount of shares corresponding to the assets
    function _convertToSharesWithTotals(
        uint256 assets,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    )
        internal
        view
        returns (uint256)
    {
        return assets.mulDiv(newTotalSupply + 10 ** _decimalsOffset(), newTotalAssets + 1, rounding);
    }

    /// @notice Converts shares to assets using provided total values
    /// @dev Used internally for more accurate conversions during fee accrual
    /// @param shares Amount of shares to convert
    /// @param newTotalSupply Total supply to use in the conversion
    /// @param newTotalAssets Total assets to use in the conversion
    /// @param rounding Rounding mode to use in the conversion
    /// @return Amount of assets corresponding to the shares
    function _convertToAssetsWithTotals(
        uint256 shares,
        uint256 newTotalSupply,
        uint256 newTotalAssets,
        Math.Rounding rounding
    )
        internal
        view
        returns (uint256)
    {
        return shares.mulDiv(newTotalAssets + 1, newTotalSupply + 10 ** _decimalsOffset(), rounding);
    }

    /// @notice Checks if a timelock duration is within allowed bounds
    /// @dev Reverts if not within MIN_TIMELOCK and MAX_TIMELOCK
    /// @param newTimelock The timelock duration to check
    function _checkTimelockBounds(uint256 newTimelock) internal pure {
        if (newTimelock > MAX_TIMELOCK) revert AboveMaxTimelock();
        if (newTimelock < MIN_TIMELOCK) revert BelowMinTimelock();
    }

    /// @notice Sets the timelock duration
    /// @dev Updates timelock and clears pending timelock
    /// @param newTimelock The new timelock duration
    function _setTimelock(uint256 newTimelock) internal {
        timelock = newTimelock;

        emit SetTimelock(_msgSender(), newTimelock);

        delete pendingTimelock;
    }

    /// @notice Sets the guardian address
    /// @dev Updates guardian and clears pending guardian
    /// @param newGuardian The new guardian address
    function _setGuardian(address newGuardian) internal {
        guardian = newGuardian;

        emit SetGuardian(_msgSender(), newGuardian);

        delete pendingGuardian;
    }

    /// @notice Updates the last recorded total assets value
    /// @dev Used to track asset growth for fee calculation
    /// @param updatedTotalAssets The new total assets value
    function _updateLastTotalAssets(uint256 updatedTotalAssets) internal {
        lastTotalAssets = updatedTotalAssets;

        emit UpdateLastTotalAssets(updatedTotalAssets);
    }

    /// @notice Accrues fees based on yield generated since last update
    /// @dev Mints fee shares to the fee recipient
    /// @return newTotalAssets The vault's total assets after accruing fees
    function _accrueFee() internal returns (uint256 newTotalAssets) {
        uint256 feeShares;
        (feeShares, newTotalAssets) = _accruedFeeShares();

        if (feeShares != 0) _mint(feeRecipient, feeShares);

        emit AccrueInterest(newTotalAssets, feeShares);
    }

    /// @notice Calculates fee shares to mint based on generated yield
    /// @dev Computes fees based on asset growth since last update
    /// @return feeShares Amount of shares to mint as fees
    /// @return newTotalAssets The vault's current total assets
    function _accruedFeeShares() internal view returns (uint256 feeShares, uint256 newTotalAssets) {
        newTotalAssets = totalAssets();

        uint256 totalInterest = newTotalAssets.zeroFloorSub(lastTotalAssets);
        if (totalInterest != 0 && fee != 0) {
            // It is acknowledged that `feeAssets` may be rounded down to 0 if `totalInterest * fee < WAD`.
            uint256 feeAssets = totalInterest.mulDiv(fee, decimals());
            // The fee assets is subtracted from the total assets in this calculation to compensate for the fact
            // that total assets is already increased by the total interest (including the fee assets).
            feeShares =
                _convertToSharesWithTotals(feeAssets, totalSupply(), newTotalAssets - feeAssets, Math.Rounding.Floor);
        }
    }
}
