// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {IERC20Metadata, IERC20} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {SafeTransferLib} from "./utils/SafeTransferLib.sol";

using UserOperationLib for PackedUserOperation;

/// @title ERC20Paymaster
/// @author Pimlico (https://github.com/pimlicolabs/erc20-paymaster/blob/main/src/ERC20Paymaster.sol)
/// @author Using Solady (https://github.com/vectorized/solady)
/// @notice An ERC-4337 Paymaster contract which is able to sponsor gas fees in exchange for ERC-20 tokens.
/// The contract refunds excess tokens. It also allows updating price configuration and withdrawing tokens by the contract owner.
/// The contract uses oracles to fetch the latest token prices.
/// @dev Inherits from BasePaymaster.
/// @custom:security-contact security@pimlico.io
contract ERC20Paymaster is BasePaymaster {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CUSTOM ERRORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The paymaster data mode is invalid. The mode should be 0, 1, 2, or 3.
    error PaymasterDataModeInvalid();

    /// @dev The token amount is higher than the limit set.
    error TokenAmountTooHigh();

    /// @dev The token limit is set to zero in a paymaster mode that uses a limit.
    error TokenLimitZero();

    /// @dev The price markup selected is higher than the price markup limit.
    error PriceMarkupTooHigh();

    /// @dev The price markup selected is lower than break-even.
    error PriceMarkupTooLow();

    /// @dev The oracle price is incomplete.
    error OracleRoundIncomplete();

    /// @dev The oracle price is stale.
    error OraclePriceStale();

    /// @dev The oracle price is less than or equal to zero.
    error OraclePriceZero();

    /// @dev The oracle decimals are not set to 8.
    error OracleDecimalsInvalid();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Emitted when the price markup is updated.
    event MarkupUpdated(uint32 priceMarkup);

    /// @dev Emitted when a user operation is sponsored by the paymaster.
    event UserOperationSponsored(
        bytes32 indexed userOpHash,
        address indexed user,
        address indexed guarantor,
        uint256 tokenAmountPaid,
        uint256 tokenPrice,
        bool paidByGuarantor
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CONSTANTS AND IMMUTABLES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The precision used for token price calculations.
    uint256 public constant PRICE_DENOMINATOR = 1e6;

    /// @dev The estimated gas cost for refunding tokens after the transaction is completed.
    uint256 public constant REFUND_POSTOP_COST = 30000;

    /// @dev The ERC20 token used for transaction fee payments.
    IERC20 public immutable token;

    /// @dev The number of decimals used by the ERC20 token.
    uint256 public immutable tokenDecimals;

    /// @dev The oracle contract used to fetch the latest ERC20 to USD token prices.
    IOracle public immutable tokenOracle;

    /// @dev The Oracle contract used to fetch the latest native asset (e.g. ETH) to USD prices.
    IOracle public immutable nativeAssetOracle;

    /// @dev The maximum price markup percentage allowed (1e6 = 100%).
    uint32 public immutable priceMarkupLimit;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          STORAGE                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The price markup percentage applied to the token price (1e6 = 100%).
    uint32 public priceMarkup;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTRUCTOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Initializes the ERC20Paymaster contract with the given parameters.
    /// @param _token The ERC20 token used for transaction fee payments.
    /// @param _entryPoint The ERC-4337 EntryPoint contract.
    /// @param _tokenOracle The oracle contract used to fetch the latest token prices.
    /// @param _nativeAssetOracle The oracle contract used to fetch the latest native asset (ETH, Matic, Avax, etc.) prices.
    /// @param _owner The address that will be set as the owner of the contract.
    /// @param _priceMarkupLimit The maximum price markup percentage allowed (1e6 = 100%).
    /// @param _priceMarkup The initial price markup percentage applied to the token price (1e6 = 100%).
    constructor(
        IERC20Metadata _token,
        IEntryPoint _entryPoint,
        IOracle _tokenOracle,
        IOracle _nativeAssetOracle,
        address _owner,
        uint32 _priceMarkupLimit,
        uint32 _priceMarkup
    ) BasePaymaster(_entryPoint) {
        token = _token;
        tokenOracle = _tokenOracle; // oracle for token -> usd
        nativeAssetOracle = _nativeAssetOracle; // oracle for native asset(eth/matic/avax..) -> usd
        priceMarkupLimit = _priceMarkupLimit;
        priceMarkup = _priceMarkup;
        transferOwnership(_owner);
        tokenDecimals = 10 ** _token.decimals();
        if (_priceMarkup < 1e6) {
            revert PriceMarkupTooLow();
        }
        if (_priceMarkup > _priceMarkupLimit) {
            revert PriceMarkupTooHigh();
        }
        if (_tokenOracle.decimals() != 8 || _nativeAssetOracle.decimals() != 8) {
            revert OracleDecimalsInvalid();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                ERC-4337 PAYMASTER FUNCTIONS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Validates a paymaster user operation and calculates the required token amount for the transaction.
    /// @dev The paymaster supports one of four modes:
    /// 0. user pays, no limit
    ///     empty bytes
    /// 1. user pays, with a limit
    ///     hex"01" + token spend limit (32 bytes)
    /// 2. user pays with a guarantor, no limit
    ///     hex"02" + guarantor address (20 bytes) + validUntil (6 bytes) + validAfter (6 bytes) + guarantor signature (dynamic bytes)
    /// 3. user pays with a guarantor, with a limit
    ///     hex"03" + token spend limit (32 bytes) + guarantor address (20 bytes) + validUntil (6 bytes) + validAfter (6 bytes) + guarantor signature (dynamic bytes)
    /// Note: modes 2 and 3 are not compatible with the default storage access rules of ERC-4337 and require a whitelist for the guarantors.
    /// @param userOp The user operation.
    /// @param userOpHash The hash of the user operation.
    /// @param maxCost The amount of tokens required for pre-funding.
    /// @return context The context containing the token amount and user sender address (if applicable).
    /// @return validationResult A uint256 value indicating the result of the validation (always 0 in this implementation).
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationResult)
    {
        (uint8 mode, bytes calldata paymasterConfig) = _parsePaymasterAndData(userOp.paymasterAndData);

        // 0xfc is the mask for the last 2 bits 00 which means mode should be 00(0) || 01(1) || 10(2) || 11(3)
        if (mode & 0xfc != 0) {
            revert PaymasterDataModeInvalid();
        }

        uint192 tokenPrice = getPrice();
        uint256 tokenAmount;
        {
            uint256 maxFeePerGas = UserOperationLib.unpackMaxFeePerGas(userOp);
            tokenAmount =
                (maxCost + (REFUND_POSTOP_COST) * maxFeePerGas) * priceMarkup * tokenPrice / (1e18 * PRICE_DENOMINATOR);
        }

        if (mode == uint8(0)) {
            SafeTransferLib.safeTransferFrom(address(token), userOp.sender, address(this), tokenAmount);
            context = abi.encodePacked(tokenAmount, tokenPrice, userOp.sender, userOpHash);
            validationResult = 0;
        } else if (mode == uint8(1)) {
            if (uint256(bytes32(paymasterConfig[0:32])) == 0) {
                revert TokenLimitZero();
            }
            if (tokenAmount > uint256(bytes32(paymasterConfig[0:32]))) {
                revert TokenAmountTooHigh();
            }
            SafeTransferLib.safeTransferFrom(address(token), userOp.sender, address(this), tokenAmount);
            context = abi.encodePacked(tokenAmount, tokenPrice, userOp.sender, userOpHash);
            validationResult = 0;
        } else if (mode == uint8(2)) {
            address guarantor = address(bytes20(paymasterConfig[0:20]));

            bool signatureValid = SignatureChecker.isValidSignatureNow(
                guarantor,
                getHash(userOp, uint48(bytes6(paymasterConfig[20:26])), uint48(bytes6(paymasterConfig[26:32])), 0),
                paymasterConfig[32:]
            );

            SafeTransferLib.safeTransferFrom(address(token), guarantor, address(this), tokenAmount);
            context = abi.encodePacked(tokenAmount, tokenPrice, userOp.sender, userOpHash, guarantor);
            validationResult = _packValidationData(
                !signatureValid, uint48(bytes6(paymasterConfig[20:26])), uint48(bytes6(paymasterConfig[26:32]))
            );
        } else {
            address guarantor = address(bytes20(paymasterConfig[32:52]));

            if (uint256(bytes32(paymasterConfig[0:32])) == 0) {
                revert TokenLimitZero();
            }
            if (tokenAmount > uint256(bytes32(paymasterConfig[0:32]))) {
                revert TokenAmountTooHigh();
            }

            bool signatureValid = SignatureChecker.isValidSignatureNow(
                guarantor,
                getHash(
                    userOp,
                    uint48(bytes6(paymasterConfig[52:58])),
                    uint48(bytes6(paymasterConfig[58:64])),
                    uint256(bytes32(paymasterConfig[0:32]))
                ),
                paymasterConfig[64:]
            );

            SafeTransferLib.safeTransferFrom(address(token), guarantor, address(this), tokenAmount);
            context = abi.encodePacked(tokenAmount, tokenPrice, userOp.sender, userOpHash, guarantor);
            validationResult = _packValidationData(
                !signatureValid, uint48(bytes6(paymasterConfig[52:58])), uint48(bytes6(paymasterConfig[58:64]))
            );
        }
    }

    /// @notice Performs post-operation tasks, such as refunding excess tokens and attempting to pay back the guarantor if there is one.
    /// @dev This function is called after a user operation has been executed or reverted.
    /// @param context The context containing the token amount and user sender address.
    /// @param actualGasCost The actual gas cost of the transaction.
    function _postOp(PostOpMode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        uint256 prefundTokenAmount = uint256(bytes32(context[0:32]));
        uint192 tokenPrice = uint192(bytes24(context[32:56]));
        address sender = address(bytes20(context[56:76]));
        bytes32 userOpHash = bytes32(context[76:108]);
        uint256 actualTokenNeeded = (actualGasCost + REFUND_POSTOP_COST * actualUserOpFeePerGas) * priceMarkup
            * tokenPrice / (1e18 * PRICE_DENOMINATOR);

        if (context.length == 128) {
            address guarantor = address(bytes20(context[108:128]));

            bool success = SafeTransferLib.trySafeTransferFrom(address(token), sender, address(this), actualTokenNeeded);
            if (success) {
                // If the token transfer is successful, transfer the held tokens back to the guarantor
                SafeTransferLib.safeTransfer(address(token), guarantor, prefundTokenAmount);
                emit UserOperationSponsored(userOpHash, sender, guarantor, actualTokenNeeded, tokenPrice, false);
            } else {
                // If the token transfer fails, the guarantor is deemed responsible for the token payment
                SafeTransferLib.safeTransfer(address(token), guarantor, prefundTokenAmount - actualTokenNeeded);
                emit UserOperationSponsored(userOpHash, sender, guarantor, actualTokenNeeded, tokenPrice, true);
            }
        } else {
            SafeTransferLib.safeTransfer(address(token), sender, prefundTokenAmount - actualTokenNeeded);
            emit UserOperationSponsored(userOpHash, sender, address(0), actualTokenNeeded, tokenPrice, false);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Updates the price markup.
    /// @param _priceMarkup The new price markup percentage (1e6 = 100%).
    function updateMarkup(uint32 _priceMarkup) external onlyOwner {
        if (_priceMarkup < 1e6) {
            revert PriceMarkupTooLow();
        }
        if (_priceMarkup > priceMarkupLimit) {
            revert PriceMarkupTooHigh();
        }
        priceMarkup = _priceMarkup;
        emit MarkupUpdated(_priceMarkup);
    }

    /// @notice Allows the contract owner to withdraw a specified amount of tokens from the contract.
    /// @param to The address to transfer the tokens to.
    /// @param amount The amount of tokens to transfer.
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(address(token), to, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      PUBLIC HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Fetches the latest token price.
    /// @return price The latest token price fetched from the oracles.
    function getPrice() public view returns (uint192) {
        uint192 tokenPrice = _fetchPrice(tokenOracle);
        uint192 nativeAssetPrice = _fetchPrice(nativeAssetOracle);
        uint192 price = nativeAssetPrice * uint192(tokenDecimals) / tokenPrice;

        return price;
    }

    /// @notice Hashes the user operation data.
    /// @param userOp The user operation data.
    /// @param validUntil The timestamp until which the user operation is valid.
    /// @param validAfter The timestamp after which the user operation is valid.
    /// @param tokenLimit The maximum amount of tokens allowed for the user operation. 0 if no limit.
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter, uint256 tokenLimit)
        public
        view
        returns (bytes32)
    {
        address sender = userOp.getSender();
        return keccak256(
            abi.encode(
                sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                uint256(bytes32(userOp.paymasterAndData[PAYMASTER_VALIDATION_GAS_OFFSET:PAYMASTER_DATA_OFFSET])),
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter,
                tokenLimit
            )
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Parses the paymasterAndData field of the user operation and returns the paymaster mode and data.
    /// @param _paymasterAndData The paymasterAndData field of the user operation.
    /// @return mode The paymaster mode.
    /// @return paymasterConfig The paymaster configuration data.
    function _parsePaymasterAndData(bytes calldata _paymasterAndData) internal pure returns (uint8, bytes calldata) {
        if (_paymasterAndData.length < 53) {
            return (0, msg.data[0:0]);
        }
        return (uint8(_paymasterAndData[52]), _paymasterAndData[53:]);
    }

    /// @notice Fetches the latest price from the given oracle.
    /// @dev This function is used to get the latest price from the tokenOracle or nativeAssetOracle.
    /// @param _oracle The oracle contract to fetch the price from.
    /// @return price The latest price fetched from the oracle.
    function _fetchPrice(IOracle _oracle) internal view returns (uint192 price) {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = _oracle.latestRoundData();
        if (answer <= 0) {
            revert OraclePriceZero();
        }
        // 2 days old price is considered stale since the price is updated every 24 hours
        if (updatedAt < block.timestamp - 60 * 60 * 24 * 2) {
            revert OracleRoundIncomplete();
        }
        if (answeredInRound < roundId) {
            revert OraclePriceStale();
        }
        price = uint192(int192(answer));
    }
}
